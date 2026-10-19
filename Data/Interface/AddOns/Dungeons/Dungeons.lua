--[[
    Dungeons.lua  -  a social group finder for every 1.12 dungeon and raid.

    A board, not a queue: nobody is teleported and nobody joins a group unless a person sends a
    normal invite. Players and groups list themselves for the dungeons that fit their level, with
    a role and a short note; everyone else browses by dungeon and either invites a player or asks
    a group's leader to join (a plain whisper the leader answers with the Invite button, which is
    the stock InviteByName). "Getting there" shows each dungeon's entrance, a meeting point note
    and opens the world map on the right zone. People you ran with land in Recent, where you can
    invite them again or endorse them; endorsement counts show on the board.

        /lfg  or  /dungeons        open the board        /lfg list | recent | off

    Transport: a hidden chat channel (OWDungeons) every Classic+ client joins, filtered out of
    every chat window, using the same escaped, chunked lines as Persona:
        !L <rev> <i>/<n> <chunk>   one chunk of the sender's listing (fields joined by '~')
        -L                         the sender removed their listing
        ?L                         "who is listed?" (listed players answer after a random pause)
        +E <name>                  the sender endorses <name> after a run
    Listing fields (append only): kind (p|g), roles (t,h,d), level, class token, dungeon keys,
    note, meet, zone, group size, presence, endorsements.
    Payloads carry no spaces, '|' or newlines (see esc). Players on the shared ignore list
    (WenillaCore.Ignore, from Social, or the stock ignore list) are never shown and never heard.
    A realm registry over .wnl could feed the same board later; nothing here needs the server.

    Lua 5.0 rules (1.12.1 client): no '#', no '%' operator, handlers read this/event/arg1..arg9.
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Dungeons"
local CHANNEL = "OWDungeons"

Dungeons = Dungeons or {}
local D = Dungeons
D.version = "1.0.0"

local CHUNK = 200            -- payload bytes per channel line
local SEND_GAP = 0.7         -- seconds between our own channel lines
local JOIN_DELAY = 8         -- after entering the world, so the stock channels get the low numbers
local JOIN_RETRY = 15
local LISTING_LIFE = 30 * 60 -- a listing lasts 30 minutes after you were last active
local RENEW_EVERY = 5 * 60   -- re-send our listing this often while listed
local SEEN_TTL = 12 * 60     -- drop a listing nobody renewed for this long
local ASK_GAP = 60           -- one "ask to join" per leader per minute
local REFRESH_GAP = 10
local NOTE_MAX, MEET_MAX = 60, 40

local strfind, strsub, strgsub, strlen, strlower, strupper = string.find, string.sub, string.gsub, string.len, string.lower, string.upper
local tinsert, tremove, getn = table.insert, table.remove, table.getn
local floor = math.floor
local DOT = "\194\183"

-- -- Dungeons and raids ---------------------------------------------------------------------
-- key, name, min, max level, entrance zone, x, y (0..100 map coordinates), raid, meeting note.
local BRM = "Meeting stone inside Blackrock Mountain"
D.LIST = {
    { "rfc", "Ragefire Chasm", 13, 18, "Orgrimmar", 51.8, 49.7 },
    { "wc", "Wailing Caverns", 17, 24, "The Barrens", 46.0, 36.4 },
    { "dm", "The Deadmines", 17, 26, "Westfall", 42.6, 71.8 },
    { "sfk", "Shadowfang Keep", 22, 30, "Silverpine Forest", 44.8, 67.8 },
    { "bfd", "Blackfathom Deeps", 24, 32, "Ashenvale", 14.2, 14.0 },
    { "stocks", "The Stockade", 24, 32, "Stormwind City", 40.5, 55.9 },
    { "gnomer", "Gnomeregan", 29, 38, "Dun Morogh", 24.4, 39.8 },
    { "rfk", "Razorfen Kraul", 29, 38, "The Barrens", 42.3, 89.9 },
    { "smgy", "Scarlet Monastery: Graveyard", 26, 36, "Tirisfal Glades", 84.9, 30.6 },
    { "smlib", "Scarlet Monastery: Library", 29, 39, "Tirisfal Glades", 84.9, 30.6 },
    { "smarm", "Scarlet Monastery: Armory", 32, 42, "Tirisfal Glades", 84.9, 30.6 },
    { "smcath", "Scarlet Monastery: Cathedral", 35, 45, "Tirisfal Glades", 84.9, 30.6 },
    { "rfd", "Razorfen Downs", 37, 46, "The Barrens", 49.0, 93.9 },
    { "ulda", "Uldaman", 41, 51, "Badlands", 44.4, 12.2 },
    { "zf", "Zul'Farrak", 44, 54, "Tanaris", 38.7, 20.0 },
    { "mara", "Maraudon", 46, 55, "Desolace", 29.1, 62.5 },
    { "st", "Sunken Temple", 50, 60, "Swamp of Sorrows", 69.9, 53.6 },
    { "brd", "Blackrock Depths", 52, 60, "Burning Steppes", 29.4, 38.3, false, BRM },
    { "lbrs", "Lower Blackrock Spire", 55, 60, "Burning Steppes", 29.4, 38.3, false, BRM },
    { "ubrs", "Upper Blackrock Spire", 58, 60, "Burning Steppes", 29.4, 38.3, false, BRM },
    { "dme", "Dire Maul: East", 55, 60, "Feralas", 59.2, 45.1 },
    { "dmw", "Dire Maul: West", 57, 60, "Feralas", 59.2, 45.1 },
    { "dmn", "Dire Maul: North", 57, 60, "Feralas", 59.2, 45.1 },
    { "scholo", "Scholomance", 58, 60, "Western Plaguelands", 69.4, 72.8 },
    { "strat", "Stratholme", 58, 60, "Eastern Plaguelands", 31.3, 15.7 },
    { "zg", "Zul'Gurub", 60, 60, "Stranglethorn Vale", 53.9, 17.6, true },
    { "aq20", "Ruins of Ahn'Qiraj", 60, 60, "Silithus", 28.6, 92.4, true },
    { "mc", "Molten Core", 60, 60, "Burning Steppes", 29.4, 38.3, true, BRM },
    { "ony", "Onyxia's Lair", 60, 60, "Dustwallow Marsh", 52.6, 76.8, true },
    { "bwl", "Blackwing Lair", 60, 60, "Burning Steppes", 29.4, 38.3, true, BRM },
    { "aq40", "Temple of Ahn'Qiraj", 60, 60, "Silithus", 28.6, 92.4, true },
    { "naxx", "Naxxramas", 60, 60, "Eastern Plaguelands", 39.9, 25.9, true },
}
D.BY_KEY, D.BY_NAME = {}, {}
for i, d in ipairs(D.LIST) do
    local e = { key = d[1], name = d[2], min = d[3], max = d[4], zone = d[5], x = d[6], y = d[7],
        raid = d[8] and true or false, stone = d[9] or "Meeting stone near the entrance", order = i }
    D.LIST[i] = e
    D.BY_KEY[e.key] = e
    D.BY_NAME[strlower(e.name)] = e
end
-- the instance zone names the client reports inside (GetRealZoneText)
D.BY_NAME["scarlet monastery"] = D.BY_KEY.smgy
D.BY_NAME["dire maul"] = D.BY_KEY.dme
D.BY_NAME["blackrock spire"] = D.BY_KEY.lbrs
D.BY_NAME["the temple of atal'hakkar"] = D.BY_KEY.st
D.BY_NAME["ahn'qiraj"] = D.BY_KEY.aq40

-- Does a dungeon suit this level? A couple of levels either side of its range.
function D.Fits(d, level)
    level = level or 1
    return level >= d.min - 2 and level <= d.max + 2
end

local ROLES = {
    t = { key = "t", word = "tank", label = "Tank", art = "Dungeons_Tank", icon = "Interface\\Icons\\Ability_Warrior_DefensiveStance" },
    h = { key = "h", word = "healer", label = "Healer", art = "Dungeons_Healer", icon = "Interface\\Icons\\Spell_Holy_FlashHeal" },
    d = { key = "d", word = "damage", label = "Damage", art = "Dungeons_Damage", icon = "Interface\\Icons\\INV_Sword_04" },
}
local ROLE_ORDER = { "t", "h", "d" }
local BY_WORD = { tank = "t", healer = "h", damage = "d", dps = "d", heal = "h" }
D.ROLES = ROLES
-- which roles each class can fill in 1.12
D.CLASS_ROLES = {
    WARRIOR = { t = true, d = true }, PALADIN = { t = true, h = true, d = true }, DRUID = { t = true, h = true, d = true },
    PRIEST = { h = true, d = true }, SHAMAN = { h = true, d = true }, HUNTER = { d = true }, ROGUE = { d = true },
    MAGE = { d = true }, WARLOCK = { d = true },
}
local CLASS_NAME = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
    SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}
local CLASS_TOKEN = {}
for k, v in pairs(CLASS_NAME) do CLASS_TOKEN[strlower(v)] = k end
local PRESENCE_TEXT = { away = "|cffffd040Away|r", busy = "|cffff6040Busy|r", lfg = "|cff40c0ffLooking for group|r" }

-- -- Small helpers -----------------------------------------------------------------------------

local function me() return UnitName("player") or "?" end
local function now() return time and time() or 0 end
local function blank(s) return not s or s == "" end
local function myClass() local _, c = UnitClass("player") return c or "WARRIOR" end

local function setting(key, default) return W:Setting(ID, key, default) end

local function classHex(token)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token or ""]
    local r, g, b
    if c then r, g, b = c.r, c.g, c.b else r, g, b = UI.ClassColor(token) end
    return string.format("ff%02x%02x%02x", floor(r * 255), floor(g * 255), floor(b * 255))
end
D.ClassHex = classHex

local function ago(t)
    if not t or t == 0 then return "" end
    local d = now() - t
    if d < 60 then return "just now" end
    if d < 3600 then return floor(d / 60) .. "m ago" end
    if d < 86400 then return floor(d / 3600) .. "h ago" end
    return floor(d / 86400) .. "d ago"
end

-- \ -> \\   _ -> \u   space -> _   newline -> \n   | -> \p   ~ -> \t   (as Persona)
local SEP = "~"
local function esc(s)
    s = strgsub(s or "", "\\", "\\\\")
    s = strgsub(s, "_", "\\u")
    s = strgsub(s, " ", "_")
    s = strgsub(s, "\r?\n", "\\n")
    s = strgsub(s, "|", "\\p")
    s = strgsub(s, "~", "\\t")
    return s
end
local function unesc(s)
    s = strgsub(s or "", "_", " ")
    s = strgsub(s, "\\(.)", function(c)
        if c == "n" then return " " elseif c == "p" then return "|" elseif c == "t" then return "~"
        elseif c == "u" then return "_" end
        return c
    end)
    return s
end
-- other players' text is shown literally ("||" draws one '|')
local function clean(s) local r = strgsub(s or "", "|", "||") return r end
local function clip(s, n) s = s or "" if strlen(s) > n then s = strsub(s, 1, n) end return s end
D.esc, D.unesc = esc, unesc

-- The shared ignore list (Social registers WenillaCore.Ignore); the stock list otherwise.
local function ignored(name)
    if blank(name) then return false end
    if W.Ignore and W.Ignore.IsIgnored then return W.Ignore.IsIgnored(name) and true or false end
    if GetNumIgnores then
        for i = 1, GetNumIgnores() do if GetIgnoreName(i) == name then return true end end
    end
    return false
end
D.IsIgnored = ignored

local function myPresence()
    if Social and Social.MyPresence then return Social:MyPresence() end
    return ""
end

local function inGroup()
    return (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0 or (GetNumPartyMembers and GetNumPartyMembers() or 0) > 0
end
local function groupSize()
    local r = GetNumRaidMembers and GetNumRaidMembers() or 0
    if r > 0 then return r end
    return (GetNumPartyMembers and GetNumPartyMembers() or 0) + 1
end
local function isLeader()
    if not inGroup() then return true end
    if (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0 then return IsRaidLeader and IsRaidLeader() and true or false end
    return IsPartyLeader and IsPartyLeader() and true or false
end

-- -- Saved data ----------------------------------------------------------------------------------
-- Dungeons_DB (per character): prefs (your listing form), listed (an active listing), recent
-- (people you ran with), endorse (your count and who endorsed you), known (others' counts).

local function db()
    if type(Dungeons_DB) ~= "table" then Dungeons_DB = {} end
    local d = Dungeons_DB
    d.prefs = d.prefs or {}
    d.prefs.dungeons = d.prefs.dungeons or {}
    d.prefs.note = d.prefs.note or ""
    d.prefs.meet = d.prefs.meet or ""
    d.recent = d.recent or {}
    d.endorse = d.endorse or { count = 0, from = {} }
    d.endorse.from = d.endorse.from or {}
    d.known = d.known or {}
    return d
end
D.DB = db

local function defaultRoles()
    local ok = D.CLASS_ROLES[myClass()] or { d = true }
    if ok.d then return { d = true } end
    for _, k in ipairs(ROLE_ORDER) do if ok[k] then return { [k] = true } end end
    return { d = true }
end

local function prefRoles()
    local p = db().prefs
    if type(p.roles) ~= "table" or not next(p.roles) then p.roles = defaultRoles() end
    -- drop roles the class cannot fill (a pref copied from another character)
    local ok = D.CLASS_ROLES[myClass()] or { d = true }
    for k in pairs(p.roles) do if not ok[k] and not inGroup() then p.roles[k] = nil end end
    if not next(p.roles) then p.roles = defaultRoles() end
    return p.roles
end

local function rolesText(roles, sep)
    local out = {}
    for _, k in ipairs(ROLE_ORDER) do if roles[k] then tinsert(out, ROLES[k].word) end end
    return table.concat(out, sep or ", ")
end

local function rolesLabel(roles)
    local out = {}
    for _, k in ipairs(ROLE_ORDER) do if roles[k] then tinsert(out, ROLES[k].label) end end
    return table.concat(out, ", ")
end

-- -- Transport -------------------------------------------------------------------------------------

D.listings = {}     -- name -> listing
D.requests = {}     -- { name, level, class, role, dungeon, at, invited }
D.browsers = {}
local outbox, sinceSend, lastJoin = {}, 0, -100
local inbox = {}    -- sender -> { rev, n, parts, got, at }
local rev = 0

local function channelId()
    local id = GetChannelName and GetChannelName(CHANNEL)
    if id and id > 0 then return id end
end

-- Opened JOIN_DELAY after entering the world, so a line queued before then (flush) can't
-- join early and take one of the stock channels' numbers (General, Trade, LocalDefense, ...).
local joinOpen = false
local function join()
    if channelId() or not JoinChannelByName or not joinOpen then return end
    if GetTime() - lastJoin < JOIN_RETRY then return end
    lastJoin = GetTime()
    JoinChannelByName(CHANNEL)
    for i = 1, (NUM_CHAT_WINDOWS or 7) do
        local cf = getglobal("ChatFrame" .. i)
        if cf and ChatFrame_RemoveChannel then ChatFrame_RemoveChannel(cf, CHANNEL) end
    end
end

local function send(line, replaceKind)
    if replaceKind then
        local keep = {}
        for _, l in ipairs(outbox) do if strsub(l, 1, 2) ~= replaceKind then tinsert(keep, l) end end
        outbox = keep
    end
    if getn(outbox) > 40 then tremove(outbox, 1) end
    tinsert(outbox, line)
end

local function flush(elapsed)
    sinceSend = sinceSend + (elapsed or 0)
    if sinceSend < SEND_GAP or getn(outbox) == 0 then return end
    local id = channelId()
    if not id then join() return end
    sinceSend = 0
    SendChatMessage(tremove(outbox, 1), "CHANNEL", nil, id)
end

-- keep the carrier channel out of every chat window
tinsert(W.chatFilters, function(ev)
    if ev ~= "CHAT_MSG_CHANNEL" and ev ~= "CHAT_MSG_CHANNEL_NOTICE"
        and ev ~= "CHAT_MSG_CHANNEL_JOIN" and ev ~= "CHAT_MSG_CHANNEL_LEAVE" then return false end
    return strfind(strlower(arg9 or arg4 or ""), strlower(CHANNEL), 1, true) ~= nil
end)

-- -- Our listing -------------------------------------------------------------------------------------

function D:MyListing()
    local d = db()
    if not d.listed then return nil end
    return d.listed
end

local function listingPayload()
    local l = D:MyListing()
    local p = db().prefs
    local keys = {}
    for _, dd in ipairs(D.LIST) do if l.dungeons[dd.key] then tinsert(keys, dd.key) end end
    local roles = {}
    for _, k in ipairs(ROLE_ORDER) do if l.roles[k] then tinsert(roles, k) end end
    local fields = {
        inGroup() and "g" or "p", table.concat(roles, ","), UnitLevel("player") or 1, myClass(),
        table.concat(keys, ","), clip(p.note, NOTE_MAX), clip(p.meet, MEET_MAX), GetRealZoneText and GetRealZoneText() or "",
        groupSize(), myPresence(), db().endorse.count or 0,
    }
    local out = {}
    for i, f in ipairs(fields) do out[i] = esc(tostring(f)) end
    return table.concat(out, SEP)
end

local lastBroadcast = -1000
function D:Broadcast()
    if not W:IsActive(ID) or not self:MyListing() then return end
    rev = rev + 1
    local data = listingPayload()
    local n = math.ceil(strlen(data) / CHUNK)
    if n < 1 then n = 1 end
    -- a burst of edits sends one copy
    local keep = {}
    for _, l in ipairs(outbox) do if strsub(l, 1, 2) ~= "!L" then tinsert(keep, l) end end
    outbox = keep
    for i = 1, n do
        send("!L " .. rev .. " " .. i .. "/" .. n .. " " .. strsub(data, (i - 1) * CHUNK + 1, i * CHUNK))
    end
    lastBroadcast = GetTime()
    self:StoreOwn()
end

-- our own card on our own board
function D:StoreOwn()
    local l = self:MyListing()
    if not l then self.listings[me()] = nil return end
    local p = db().prefs
    local roles, dungeons = {}, {}
    for k in pairs(l.roles) do roles[k] = true end
    for k in pairs(l.dungeons) do dungeons[k] = true end
    self.listings[me()] = {
        name = me(), kind = inGroup() and "g" or "p", roles = roles, level = UnitLevel("player") or 1, class = myClass(),
        dungeons = dungeons, note = p.note or "", meet = p.meet or "", zone = GetRealZoneText and GetRealZoneText() or "",
        size = groupSize(), presence = myPresence(), endorse = db().endorse.count or 0, t = GetTime(), own = true,
    }
end

function D:List(dungeons, roles)
    local d = db()
    local set, any = {}, false
    for k, on in pairs(dungeons or d.prefs.dungeons) do if on and D.BY_KEY[k] then set[k] = true; any = true end end
    if not any then W.Print("Dungeons: pick at least one dungeon to list for.") return false end
    if inGroup() and not isLeader() then W.Print("Dungeons: only your group leader can list the group.") return false end
    local r = {}
    for k, on in pairs(roles or prefRoles()) do if on then r[k] = true end end
    if not next(r) then r = defaultRoles() end
    d.listed = { dungeons = set, roles = r, at = now() }
    self.lastActive = now()
    self:Broadcast()
    self:Refresh()
    return true
end

function D:Unlist(quiet, reason)
    local d = db()
    if not d.listed then return end
    d.listed = nil
    self.listings[me()] = nil
    send("-L", "!L")
    if not quiet then W.Print(reason or "Dungeons: your listing is removed.") end
    self:Refresh()
end

-- seconds left before the listing lapses (it renews while you're active)
function D:TimeLeft()
    local l = self:MyListing()
    if not l then return 0 end
    local base = math.max(l.at or 0, self.lastActive or 0)
    if not setting("autoRenew", true) then base = l.at or 0 end
    return base + LISTING_LIFE - now()
end

-- -- Receiving ------------------------------------------------------------------------------------------

local function split(s, sep)
    return W.Split(s, sep)
end

function D:Receive(msg, sender)
    if blank(msg) or blank(sender) or sender == me() or ignored(sender) then return end
    local kind = strsub(msg, 1, 2)
    if kind == "!L" then
        local _, _, r, i, n, chunk = strfind(msg, "^!L (%d+) (%d+)/(%d+) (%S*)$")
        if not r then return end
        r, i, n = tonumber(r), tonumber(i), tonumber(n)
        if n > 8 or i < 1 or i > n then return end
        local box = inbox[sender]
        if not box or box.rev ~= r or box.n ~= n then box = { rev = r, n = n, parts = {}, got = 0 } inbox[sender] = box end
        box.at = GetTime()
        if not box.parts[i] then box.parts[i] = chunk; box.got = box.got + 1 end
        if box.got == n then
            inbox[sender] = nil
            self:Store(sender, table.concat(box.parts))
        end
    elseif kind == "-L" then
        if self.listings[sender] then self.listings[sender] = nil; self:Refresh() end
    elseif kind == "?L" then
        if self:MyListing() and GetTime() - lastBroadcast > 30 then
            self.replyAt = GetTime() + 1 + math.random() * 5
        end
    elseif kind == "+E" then
        local _, _, target = strfind(msg, "^%+E (%S+)")
        if target == me() then self:Endorsed(sender) end
    end
end

function D:Store(sender, data)
    local f, n = split(data, SEP)
    if n < 5 then return end
    local x = {}
    for i = 1, n do x[i] = unesc(f[i]) end
    local roles, dungeons, any = {}, {}, false
    for _, k in ipairs((split(x[2] or "", ","))) do if ROLES[k] then roles[k] = true end end
    for _, k in ipairs((split(x[5] or "", ","))) do if D.BY_KEY[k] then dungeons[k] = true; any = true end end
    if not any then return end
    local class = strupper(x[4] or "")
    if not CLASS_NAME[class] then class = "WARRIOR" end
    local level = tonumber(x[3]) or 1
    if level < 1 or level > 60 then level = 1 end
    local l = {
        name = sender, kind = (x[1] == "g") and "g" or "p", roles = roles, level = level, class = class,
        dungeons = dungeons, note = clip(x[6], NOTE_MAX), meet = clip(x[7], MEET_MAX), zone = clip(x[8], 40),
        size = math.max(1, math.min(40, tonumber(x[9]) or 1)), presence = PRESENCE_TEXT[x[10] or ""] and x[10] or "",
        endorse = math.max(0, math.min(9999, tonumber(x[11]) or 0)), t = GetTime(),
    }
    local isNew = not self.listings[sender]
    self.listings[sender] = l
    db().known[sender] = l.endorse
    if isNew and W:IsActive(ID) and setting("announceListings", false) then
        DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Dungeons]|r " .. sender .. " is looking for " .. self:DungeonText(l, 2) .. ".")
    end
    self:Refresh()
end

-- "The Deadmines, Wailing Caverns +2"
function D:DungeonText(l, most)
    local names, total = {}, 0
    for _, d in ipairs(D.LIST) do
        if l.dungeons[d.key] then
            total = total + 1
            if total <= (most or 2) then tinsert(names, d.name) end
        end
    end
    local s = table.concat(names, ", ")
    if total > (most or 2) then s = s .. " +" .. (total - (most or 2)) end
    return s
end

-- the first of a listing's dungeons the filter (or the viewer's level) points at
function D:PickDungeon(l, want)
    if want and l.dungeons[want] then return D.BY_KEY[want] end
    local lvl = UnitLevel("player") or 1
    local first
    for _, d in ipairs(D.LIST) do
        if l.dungeons[d.key] then
            first = first or d
            if D.Fits(d, lvl) then return d end
        end
    end
    return first
end

function D:Expire()
    local t = GetTime()
    local changed = false
    for name, l in pairs(self.listings) do
        if not l.own and not l.demo and t - (l.t or 0) > SEEN_TTL then self.listings[name] = nil; changed = true end
    end
    for k, box in pairs(inbox) do if t - (box.at or 0) > 60 then inbox[k] = nil end end
    if changed then self:Refresh() end
end

-- -- Asking, inviting, requests -----------------------------------------------------------------------------

D.asked = {}

function D:RequestText(dungeon, role)
    local lvl = UnitLevel("player") or 1
    return "[Dungeons] " .. me() .. ", " .. lvl .. " " .. (CLASS_NAME[myClass()] or "") .. ", "
        .. (ROLES[role] and ROLES[role].word or "damage") .. ", wants " .. dungeon.name
end

-- Whisper a group's leader. Nothing else happens until the leader sends a normal invite.
function D:AskToJoin(name, dungeonKey)
    local l = self.listings[name]
    if not l or l.own then return false end
    if ignored(name) then return false end
    if self.asked[name] and GetTime() - self.asked[name] < ASK_GAP then
        W.Print("Dungeons: you already asked " .. name .. ". Give them a moment to answer.")
        return false
    end
    local d = self:PickDungeon(l, dungeonKey)
    if not d then return false end
    local roles = prefRoles()
    local role = "d"
    for _, k in ipairs(ROLE_ORDER) do if roles[k] and l.roles[k] then role = k break end end
    if not (roles[role] and l.roles[role]) then
        for _, k in ipairs(ROLE_ORDER) do if roles[k] then role = k break end end
    end
    self.asked[name] = GetTime()
    self.groupDungeon = d.key
    SendChatMessage(self:RequestText(d, role), "WHISPER", nil, name)
    self:Refresh()
    return true
end

-- A player's listing: invite them (the stock invite; they accept or decline as usual).
function D:Invite(name, dungeonKey)
    if blank(name) or name == me() then return end
    local l = self.listings[name]
    local d = l and self:PickDungeon(l, dungeonKey)
    if d then self.groupDungeon = d.key end
    InviteByName(name)
    self.invited = self.invited or {}
    self.invited[name] = GetTime()
    self:Refresh()
end

local function parseRequest(msg)
    local _, _, nm, lvl, class, role, dname = strfind(msg or "", "^%[Dungeons%] (%S+), (%d+) ([%a ]+), (%a+), wants (.+)$")
    if not nm then return nil end
    return { level = tonumber(lvl), class = CLASS_TOKEN[strlower(class)] or "WARRIOR", role = BY_WORD[strlower(role)] or "d",
        dungeon = D.BY_NAME[strlower(dname)] }
end
D.ParseRequest = parseRequest

function D:OnWhisper(msg, sender)
    if blank(sender) or ignored(sender) then return end
    local r = parseRequest(msg)
    if not r or not r.dungeon then return end
    if not self:MyListing() then return end
    for i, old in ipairs(self.requests) do
        if old.name == sender then tremove(self.requests, i) break end
    end
    r.name, r.at = sender, now()
    tinsert(self.requests, 1, r)
    while getn(self.requests) > 12 do tremove(self.requests) end
    if W:IsActive(ID) and setting("requestToasts", true) then
        UI.Toast({ icon = ROLES[r.role].icon, title = sender .. " wants to join",
            text = r.level .. " " .. (CLASS_NAME[r.class] or "") .. ", " .. ROLES[r.role].word .. DOT .. " " .. r.dungeon.name,
            color = { 0.25, 0.75, 1 }, sound = setting("sounds", true) and "igPlayerInvite" or nil,
            onClick = function() D:Show("mine") end })
    end
    if self.tabs and self.tabs:Selected() ~= "mine" then self.tabs:SetUnread("mine", true) end
    self:Refresh()
end

function D:InviteRequest(i)
    local r = self.requests[i]
    if not r then return end
    r.invited = true
    self.groupDungeon = r.dungeon and r.dungeon.key or self.groupDungeon
    InviteByName(r.name)
    self:Refresh()
end

function D:DeclineRequest(i)
    tremove(self.requests, i)
    self:Refresh()
end

-- -- Recent runs and endorsements -------------------------------------------------------------------------------

local function currentDungeon()
    local z = GetRealZoneText and strlower(GetRealZoneText() or "") or ""
    local d = D.BY_NAME[z]
    if d then return d.key end
    return D.groupDungeon
end

function D:Remember(name, class, level)
    if blank(name) or name == me() then return end
    local list = db().recent
    local key = currentDungeon()
    local t = now()
    for i, r in ipairs(list) do
        if r.name == name then
            if t - (r.at or 0) < 3 * 3600 and (r.dungeon == key or not key or not r.dungeon) then
                r.at, r.class, r.level = t, class or r.class, level or r.level
                r.dungeon = r.dungeon or key
                return
            end
            tremove(list, i)
            break
        end
    end
    tinsert(list, 1, { name = name, class = class, level = level, dungeon = key, at = t })
    while getn(list) > 40 do tremove(list) end
end

function D:ScanGroup()
    local r = GetNumRaidMembers and GetNumRaidMembers() or 0
    if r > 0 then
        for i = 1, r do
            local n, _, _, lvl, _, class = GetRaidRosterInfo(i)
            if n then self:Remember(n, class, lvl) end
        end
    else
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) then
                local _, class = UnitClass(u)
                self:Remember(UnitName(u), class, UnitLevel(u))
            end
        end
    end
    if not inGroup() then self.groupDungeon = nil end
    self:Refresh()
end

function D:CanEndorse(r)
    return r and not r.endorsed and now() - (r.at or 0) < 2 * 86400
end

function D:Endorse(name)
    for _, r in ipairs(db().recent) do
        if r.name == name and self:CanEndorse(r) then
            r.endorsed = true
            send("+E " .. name)
            W.Print("Dungeons: you endorsed " .. name .. ". Thanks for making groups better.")
            self:Refresh()
            return true
        end
    end
    return false
end

function D:Endorsed(from)
    local e = db().endorse
    local t = now()
    if e.from[from] and t - e.from[from] < 20 * 3600 then return end   -- once a day per player
    e.from[from] = t
    e.count = (e.count or 0) + 1
    if W:IsActive(ID) then
        W.Print("Dungeons: " .. from .. " endorsed you. You have " .. e.count .. " endorsement" .. (e.count == 1 and "" or "s") .. ".")
        if setting("requestToasts", true) then
            UI.Toast({ icon = "Interface\\Icons\\INV_Misc_Note_02", title = "Endorsed by " .. from,
                text = "You now have " .. e.count .. " endorsement" .. (e.count == 1 and "" or "s") .. ".", color = { 1, 0.82, 0 } })
        end
    end
    if self:MyListing() then self:Broadcast() end
    self:Refresh()
end

function D:EndorseCount(name)
    if name == me() then return db().endorse.count or 0 end
    local l = self.listings[name]
    if l then return l.endorse or 0 end
    return db().known[name] or 0
end

-- -- Getting there ------------------------------------------------------------------------------------------------

local function zoneIndex(zone)
    if not GetMapZones then return nil end
    for c = 1, 2 do
        local zones = { GetMapZones(c) }
        for i, z in ipairs(zones) do if z == zone then return c, i end end
    end
end

-- The Quests addon's waypoint arrow and ring pin, when it offers one (Compass:SetWaypoint).
function D:CanWaypoint()
    return (Compass and Compass.SetWaypoint and W:IsActive("Quests")) and true or false
end
function D:Waypoint(d)
    if not d or not self:CanWaypoint() then return false end
    Compass:SetWaypoint({ x = d.x / 100, y = d.y / 100, zone = d.zone, title = d.name .. " entrance",
        kind = "SPOT", label = d.stone })
    return true
end

function D:ShowOnMap(d)
    if not d then return end
    if WorldMapFrame and not WorldMapFrame:IsShown() then
        if ShowUIPanel then ShowUIPanel(WorldMapFrame) else WorldMapFrame:Show() end
    end
    local c, z = zoneIndex(d.zone)
    if c and SetMapZoom then SetMapZoom(c, z) end
    W.Print("Dungeons: " .. d.name .. " entrance - " .. d.zone .. " " .. string.format("%.1f, %.1f", d.x, d.y) .. ". " .. d.stone .. ".")
end

function D:TravelText(d, l)
    if not d then return "", "" end
    local head = d.name .. "  |cff9da3b4" .. d.min .. (d.max ~= d.min and ("-" .. d.max) or "") .. (d.raid and " raid" or "") .. "|r"
    local body = "Entrance: " .. d.zone .. " " .. string.format("%.1f, %.1f", d.x, d.y) .. "   " .. DOT .. "   " .. d.stone
    local meet = l and not blank(l.meet) and l.meet or nil
    if l and l.own then meet = db().prefs.meet end
    if not blank(meet) then body = body .. "\nMeet at: " .. clean(meet) end
    return head, body
end

-- -- Browser: the board, used by the window's Browse tab and by Social's Group tab ----------------------------------

local ROW_H = 34

local function roleTexture(tex, k)
    if not W:Art(tex, ROLES[k].art, ROLES[k].icon) then tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else tex:SetTexCoord(0, 1, 0, 1) end
end
D.RoleTexture = roleTexture

local function starTexture(tex)
    if not W:Art(tex, "Dungeons_Star", "Interface\\Icons\\INV_Misc_Note_02") then tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else tex:SetTexCoord(0, 1, 0, 1) end
end
D.StarTexture = starTexture

local function filterLabel(b)
    if b.filter == "fit" then return "Fits my level" end
    if b.filter == "all" then return "Every dungeon" end
    local d = D.BY_KEY[b.filter]
    return d and d.name or "Fits my level"
end

local ROLE_FILTERS = { { "", "Any role" }, { "t", "Tanks" }, { "h", "Healers" }, { "d", "Damage" } }

function D:Items(b)
    local lvl = UnitLevel("player") or 1
    local items = {}
    for _, l in pairs(self.listings) do
        if not ignored(l.name) then
            local ok
            if b.filter == "all" then ok = true
            elseif b.filter == "fit" then
                ok = false
                for k in pairs(l.dungeons) do if D.Fits(D.BY_KEY[k], lvl) then ok = true end end
            else ok = l.dungeons[b.filter] and true or false end
            if ok and b.role ~= "" and not l.roles[b.role] then ok = false end
            if ok then tinsert(items, l) end
        end
    end
    table.sort(items, function(a, c)
        if (a.own and 1 or 0) ~= (c.own and 1 or 0) then return a.own and true or false end
        if a.kind ~= c.kind then return a.kind == "g" end
        return (a.t or 0) > (c.t or 0)
    end)
    return items
end

local function tooltipFor(row)
    local l = row.item
    if not l then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText("|c" .. classHex(l.class) .. l.name .. "|r", 1, 1, 1)
    GameTooltip:AddLine("Level " .. l.level .. " " .. (CLASS_NAME[l.class] or "") .. "  " .. DOT .. "  " .. rolesLabel(l.roles)
        .. (l.kind == "g" and " needed" or ""), 0.85, 0.85, 0.9)
    if l.kind == "g" then GameTooltip:AddLine("Group of " .. l.size .. (l.size > 5 and "" or "/5"), 0.6, 0.85, 1) end
    GameTooltip:AddLine(D:DungeonText(l, 6), 1, 0.82, 0, 1)
    if not blank(l.note) then GameTooltip:AddLine("\"" .. clean(l.note) .. "\"", 1, 1, 1, 1) end
    if not blank(l.meet) then GameTooltip:AddLine("Meet at: " .. clean(l.meet), 0.75, 0.9, 0.75, 1) end
    if not blank(l.zone) then GameTooltip:AddLine("In " .. clean(l.zone), 0.6, 0.62, 0.7) end
    if PRESENCE_TEXT[l.presence or ""] then GameTooltip:AddLine(PRESENCE_TEXT[l.presence]) end
    if Social and Social.IsLive and Social:IsLive(l.name) then GameTooltip:AddLine(Social.LIVE_TAG .. "|cffffd8d0  streaming now|r") end
    local e = D:EndorseCount(l.name)
    if e > 0 then GameTooltip:AddLine(e .. " endorsement" .. (e == 1 and "" or "s") .. " from other players", 1, 0.82, 0) end
    -- their Persona, when Persona is loaded
    if Persona and Persona.Get and W:IsActive("Persona") and not l.own then
        local p = Persona.Get(l.name)
        if not p and Persona.Request then Persona.Request(l.name) end
        if p then
            if not blank(p.name) and p.name ~= l.name then GameTooltip:AddLine("Persona: " .. clean(p.name), 0.85, 0.65, 1) end
            if not blank(p.title) then GameTooltip:AddLine("<" .. clean(p.title) .. ">", 0.85, 0.65, 1) end
            local st = { ic = "In character", ooc = "Out of character", lfrp = "Looking for roleplay", st = "Storytelling" }
            if st[p.status or ""] then GameTooltip:AddLine(st[p.status], 0.7, 0.6, 0.9) end
        end
    end
    if not l.own then GameTooltip:AddLine(l.kind == "g" and "Ask to join whispers the leader." or "Invite sends a normal group invite.", 0.5, 0.5, 0.55) end
    GameTooltip:Show()
end

function D:CreateBrowser(parent, opts)
    opts = opts or {}
    local width, height = opts.width or 420, opts.height or 300
    local b = { filter = "fit", role = "", travel = opts.travel }
    local f = CreateFrame("Frame", opts.name, parent)
    f:SetWidth(width)
    f:SetHeight(height)
    b.frame = f

    local dbtn = CreateFrame("Button", opts.name and (opts.name .. "Filter"), f)
    UI.Skin(dbtn, "inset")
    dbtn:SetWidth(170)
    dbtn:SetHeight(18)
    dbtn:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    dbtn.text = UI.Label(dbtn, 10, UI.ACCENT)
    dbtn.text:SetPoint("LEFT", dbtn, "LEFT", 6, 0)
    dbtn:SetScript("OnClick", function()
        local lvl = UnitLevel("player") or 1
        local items = {
            { text = "Fits my level", checked = b.filter == "fit", func = function() b.filter = "fit"; D:RefreshBrowser(b) end },
            { text = "Every dungeon", checked = b.filter == "all", func = function() b.filter = "all"; D:RefreshBrowser(b) end },
        }
        for _, d in ipairs(D.LIST) do
            if D.Fits(d, lvl) then
                local key = d.key
                tinsert(items, { text = d.name, checked = b.filter == key, func = function() b.filter = key; D:RefreshBrowser(b) end })
            end
        end
        UI.Menu(dbtn, items)
    end)
    b.dungeonButton = dbtn

    local rbtn = CreateFrame("Button", nil, f)
    UI.Skin(rbtn, "inset")
    rbtn:SetWidth(80)
    rbtn:SetHeight(18)
    rbtn:SetPoint("LEFT", dbtn, "RIGHT", 4, 0)
    rbtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    rbtn.text = UI.Label(rbtn, 10, { 0.9, 0.9, 0.95 })
    rbtn.text:SetPoint("CENTER", rbtn, "CENTER", 0, 0)
    rbtn.text:SetJustifyH("CENTER")
    b.roleIndex = 1
    rbtn:SetScript("OnClick", function()
        local n = getn(ROLE_FILTERS)
        b.roleIndex = b.roleIndex + ((arg1 == "RightButton") and -1 or 1)
        if b.roleIndex > n then b.roleIndex = 1 elseif b.roleIndex < 1 then b.roleIndex = n end
        b.role = ROLE_FILTERS[b.roleIndex][1]
        D:RefreshBrowser(b)
    end)
    b.roleButton = rbtn

    local refresh = UI.Button(f, "Refresh", 64, 18, function() D:AskWho(true) end)
    refresh:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    b.count = UI.Label(f, 10, UI.MUTED)
    b.count:SetPoint("RIGHT", refresh, "LEFT", -6, 0)
    b.count:SetJustifyH("RIGHT")

    local travelH = opts.travel and 64 or 0
    local listH = height - 24 - travelH
    local rows = floor((listH - 4) / ROW_H)
    local inset = CreateFrame("Frame", nil, f)
    UI.Skin(inset, "inset")
    inset:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -22)
    inset:SetWidth(width)
    inset:SetHeight(rows * ROW_H + 4)
    b.list = UI.ScrollList(inset, { width = width - 4, height = rows * ROW_H, rowHeight = ROW_H,
        build = function(row, i)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(row)
            hl:SetTexture(1, 0.82, 0, 0.07)
            row.sel = row:CreateTexture(nil, "BACKGROUND")
            row.sel:SetAllPoints(row)
            row.sel:SetTexture(1, 0.82, 0, 0.10)
            row.icons = {}
            for j = 1, 3 do
                local t = row:CreateTexture(nil, "ARTWORK")
                t:SetWidth(14)
                t:SetHeight(14)
                t:SetPoint("TOPLEFT", row, "TOPLEFT", 4 + (j - 1) * 15, -3)
                row.icons[j] = t
            end
            row.size = UI.Label(row, 9, UI.MUTED)
            row.size:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -20)
            row.name = UI.Label(row, 11, { 1, 1, 1 }, "OUTLINE")
            row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 52, -3)
            row.star = row:CreateTexture(nil, "ARTWORK")
            row.star:SetWidth(12)
            row.star:SetHeight(12)
            row.star:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
            starTexture(row.star)
            row.stars = UI.Label(row, 10, UI.ACCENT)
            row.stars:SetPoint("LEFT", row.star, "RIGHT", 1, 0)
            row.info = UI.Label(row, 10, UI.MUTED)
            row.info:SetPoint("TOPLEFT", row, "TOPLEFT", 52, -18)
            row.info:SetWidth(width - 210)
            if row.info.SetNonSpaceWrap then row.info:SetNonSpaceWrap(false) end
            row.info:SetHeight(12)
            row.act = UI.Button(row, "Ask to join", 78, 18)
            row.act:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.act:SetScript("OnClick", function()
                local l = row.item
                if not l then return end
                if l.kind == "g" then D:AskToJoin(l.name, b.filter) else D:Invite(l.name, b.filter) end
            end)
            row.wsp = UI.Button(row, "Whisper", 58, 18)
            row.wsp:SetPoint("RIGHT", row.act, "LEFT", -3, 0)
            row.wsp:SetScript("OnClick", function()
                if row.item and ChatFrame_OpenChat then ChatFrame_OpenChat("/w " .. row.item.name .. " ") end
            end)
            row:SetScript("OnEnter", function() tooltipFor(row) end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row:SetScript("OnClick", function()
                local l = row.item
                if arg1 == "RightButton" and l and not l.own and W.Report then
                    UI.Menu(row, { { text = l.name, title = true },
                        { text = "Whisper", func = function() if ChatFrame_OpenChat then ChatFrame_OpenChat("/w " .. l.name .. " ") end end },
                        { text = "Report...", color = { 1, 0.45, 0.4 }, func = function() W.Report.Open(l.name, "dungeons") end } })
                    return
                end
                b.selected = l and l.name
                D:RefreshBrowser(b)
            end)
            if opts.name then b["row" .. i] = row; setglobal(opts.name .. "Row" .. i, row) end
        end,
        update = function(row, l)
            local n = 0
            for _, k in ipairs(ROLE_ORDER) do
                if l.roles[k] then n = n + 1; roleTexture(row.icons[n], k); row.icons[n]:Show() end
            end
            for j = n + 1, 3 do row.icons[j]:Hide() end
            row.size:SetText(l.kind == "g" and ("group " .. l.size .. (l.size > 5 and "" or "/5")) or "")
            local presence = PRESENCE_TEXT[l.presence or ""] and ("  " .. PRESENCE_TEXT[l.presence]) or ""
            local live = (Social and Social.LiveTag) and Social:LiveTag(l.name) or ""     -- streaming (Social/Live.lua)
            row.name:SetText("|c" .. classHex(l.class) .. l.name .. "|r" .. live .. "  |cffc8ccd6" .. l.level .. " " .. (CLASS_NAME[l.class] or "") .. "|r" .. presence)
            local e = D:EndorseCount(l.name)
            if e > 0 then row.star:Show(); row.stars:SetText(tostring(e)) else row.star:Hide(); row.stars:SetText("") end
            local bits = { D:DungeonText(l, 2) }
            if not blank(l.note) then tinsert(bits, "|cffe8e8ee" .. clean(l.note) .. "|r") end
            if not blank(l.zone) then tinsert(bits, clean(l.zone)) end
            row.info:SetText(table.concat(bits, "  " .. DOT .. "  "))
            if l.own then
                row.act:Hide(); row.wsp:Hide()
            else
                row.act:Show(); row.wsp:Show()
                local asked = D.asked[l.name] and GetTime() - D.asked[l.name] < ASK_GAP
                local invited = D.invited and D.invited[l.name] and GetTime() - D.invited[l.name] < ASK_GAP
                if l.kind == "g" then row.act:SetText(asked and "Asked" or "Ask to join")
                else row.act:SetText(invited and "Invited" or "Invite") end
            end
            if b.selected == l.name then row.sel:Show() else row.sel:Hide() end
        end,
    })
    b.list:SetPoint("TOPLEFT", inset, "TOPLEFT", 2, -2)
    b.empty = UI.Label(inset, 11, UI.MUTED)
    b.empty:SetPoint("CENTER", inset, "CENTER", 0, 10)
    b.empty:SetWidth(width - 60)
    b.empty:SetJustifyH("CENTER")

    if opts.travel then
        local tr = CreateFrame("Frame", nil, f)
        UI.Skin(tr, "panel")
        tr:SetPoint("TOPLEFT", inset, "BOTTOMLEFT", 0, -4)
        tr:SetWidth(width)
        tr:SetHeight(travelH - 4)
        local cap = UI.Label(tr, 9, UI.MUTED, "OUTLINE")
        cap:SetPoint("TOPLEFT", tr, "TOPLEFT", 8, -6)
        cap:SetText("GETTING THERE")
        tr.head = UI.Label(tr, 11, UI.ACCENT)
        tr.head:SetPoint("LEFT", cap, "RIGHT", 8, 0)
        tr.body = UI.Label(tr, 10, { 0.85, 0.86, 0.9 })
        tr.body:SetPoint("TOPLEFT", tr, "TOPLEFT", 8, -22)
        tr.body:SetWidth(width - 120)
        tr.map = UI.Button(tr, "Show on map", 96, 18, function() D:ShowOnMap(b.travelDungeon) end)
        tr.map:SetPoint("TOPRIGHT", tr, "TOPRIGHT", -6, -6)
        tr.pin = UI.Button(tr, "Pin it", 96, 18, function()
            if D:Waypoint(b.travelDungeon) then W.Print("Dungeons: pinned the " .. b.travelDungeon.name .. " entrance on your minimap ring.") end
        end)
        tr.pin:SetPoint("TOPRIGHT", tr.map, "BOTTOMRIGHT", 0, -4)
        b.travelFrame = tr
    end

    tinsert(self.browsers, b)
    self:RefreshBrowser(b)
    return b
end

function D:RefreshBrowser(b)
    local items = self:Items(b)
    b.list:SetItems(items)
    local players, groups = 0, 0
    for _, l in ipairs(items) do if l.kind == "g" then groups = groups + 1 else players = players + 1 end end
    b.count:SetText(players .. " player" .. (players == 1 and "" or "s") .. "  " .. DOT .. "  " .. groups .. " group" .. (groups == 1 and "" or "s"))
    b.dungeonButton.text:SetText(filterLabel(b))
    b.roleButton.text:SetText(ROLE_FILTERS[b.roleIndex][2])
    if getn(items) == 0 then
        if not channelId() then b.empty:SetText("Connecting to the group finder...")
        else b.empty:SetText("Nobody is listed for these dungeons right now.\nList yourself under My Listing and others will find you.") end
        b.empty:Show()
    else
        b.empty:Hide()
    end
    if b.travelFrame then
        local sel = b.selected and self.listings[b.selected]
        local d
        if sel then d = self:PickDungeon(sel, b.filter)
        elseif D.BY_KEY[b.filter] then d = D.BY_KEY[b.filter]
        elseif self:MyListing() then d = self:PickDungeon(self.listings[me()] or { dungeons = self:MyListing().dungeons }, nil)
        else
            local lvl = UnitLevel("player") or 1
            for _, x in ipairs(D.LIST) do if not d and lvl >= x.min and lvl <= x.max then d = x end end
            d = d or D.LIST[1]
        end
        b.travelDungeon = d
        local head, body = self:TravelText(d, sel)
        b.travelFrame.head:SetText(head)
        b.travelFrame.body:SetText(body)
        if self:CanWaypoint() then b.travelFrame.pin:Show() else b.travelFrame.pin:Hide() end
    end
end

-- -- Window --------------------------------------------------------------------------------------------------------

local WIN_W, WIN_H = 470, 456
local win, pages = nil, {}

local function roleToggle(parent, k)
    local btn = CreateFrame("Button", nil, parent)
    UI.Skin(btn, "inset")
    btn:SetWidth(84)
    btn:SetHeight(24)
    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetWidth(18)
    btn.icon:SetHeight(18)
    btn.icon:SetPoint("LEFT", btn, "LEFT", 4, 0)
    roleTexture(btn.icon, k)
    btn.label = UI.Label(btn, 10, { 1, 1, 1 })
    btn.label:SetPoint("LEFT", btn.icon, "RIGHT", 5, 0)
    btn.label:SetText(ROLES[k].label)
    btn.key = k
    return btn
end

local function editBox(parent, name, width, maxLetters)
    local e = CreateFrame("EditBox", name, parent)
    UI.Skin(e, "inset")
    e:SetWidth(width)
    e:SetHeight(20)
    e:SetAutoFocus(false)
    e:SetFontObject(GameFontHighlightSmall)
    if e.SetTextInsets then e:SetTextInsets(6, 6, 0, 0) end
    e:SetMaxLetters(maxLetters)
    e:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    e:SetScript("OnEnterPressed", function() this:ClearFocus() end)
    return e
end

local function buildMine(p)
    local mine = {}
    mine.status = UI.Label(p, 11, { 1, 1, 1 })
    mine.status:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -2)
    mine.status:SetWidth(WIN_W - 30)

    mine.rolesLabel = UI.Label(p, 10, UI.MUTED, "OUTLINE")
    mine.rolesLabel:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -24)
    mine.roles = {}
    for i, k in ipairs(ROLE_ORDER) do
        local btn = roleToggle(p, k)
        btn:SetPoint("TOPLEFT", p, "TOPLEFT", 2 + (i - 1) * 88, -38)
        btn:SetScript("OnClick", function()
            local roles = prefRoles()
            local ok = D.CLASS_ROLES[myClass()] or {}
            if not ok[btn.key] and not inGroup() then return end
            if roles[btn.key] then
                roles[btn.key] = nil
                if not next(roles) then roles[btn.key] = true end
            else
                roles[btn.key] = true
            end
            D:Refresh()
        end)
        mine.roles[k] = btn
    end

    local cap = UI.Label(p, 10, UI.MUTED, "OUTLINE")
    cap:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -70)
    mine.dlabel = cap
    mine.showAll = UI.Button(p, "Show all", 64, 16, function()
        mine.all = not mine.all
        D:Refresh()
    end)
    mine.showAll:SetPoint("TOPLEFT", p, "TOPLEFT", 166, -66)
    local inset = CreateFrame("Frame", nil, p)
    UI.Skin(inset, "inset")
    inset:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -86)
    inset:SetWidth(232)
    inset:SetHeight(200)
    mine.list = UI.ScrollList(inset, { width = 228, height = 192, rowHeight = 16, name = "Dungeons_PickList",
        build = function(row, i)
            row.check = row:CreateTexture(nil, "OVERLAY")
            row.check:SetWidth(14)
            row.check:SetHeight(14)
            row.check:SetPoint("LEFT", row, "LEFT", 2, 0)
            row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
            row.box = row:CreateTexture(nil, "ARTWORK")
            row.box:SetWidth(10)
            row.box:SetHeight(10)
            row.box:SetPoint("CENTER", row.check, "CENTER", 0, 0)
            row.box:SetTexture(0.2, 0.21, 0.25, 1)
            row.text = UI.Label(row, 10, { 1, 1, 1 })
            row.text:SetPoint("LEFT", row, "LEFT", 20, 0)
            row.range = UI.Label(row, 10, UI.MUTED)
            row.range:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            row.range:SetJustifyH("RIGHT")
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(row)
            hl:SetTexture(1, 0.82, 0, 0.08)
            row:SetScript("OnClick", function()
                local d = row.item
                if not d then return end
                local set = db().prefs.dungeons
                set[d.key] = (not set[d.key]) and true or nil
                D:Refresh()
            end)
            setglobal("Dungeons_Pick" .. i, row)
        end,
        update = function(row, d)
            local on = db().prefs.dungeons[d.key]
            if on then row.check:Show() else row.check:Hide() end
            row.text:SetText(d.name)
            local fits = D.Fits(d, UnitLevel("player") or 1)
            if fits then row.text:SetTextColor(1, 1, 1) else row.text:SetTextColor(0.55, 0.56, 0.6) end
            row.range:SetText(d.min .. (d.max ~= d.min and ("-" .. d.max) or "") .. (d.raid and " raid" or ""))
        end,
    })
    mine.list:SetPoint("TOPLEFT", inset, "TOPLEFT", 2, -4)

    local x = 244
    local nl = UI.Label(p, 10, UI.MUTED, "OUTLINE")
    nl:SetPoint("TOPLEFT", p, "TOPLEFT", x, -70)
    nl:SetText("NOTE FOR THE BOARD")
    mine.note = editBox(p, "Dungeons_Note", WIN_W - x - 18, NOTE_MAX)
    mine.note:SetPoint("TOPLEFT", p, "TOPLEFT", x, -84)
    mine.note:SetScript("OnTextChanged", function() db().prefs.note = this:GetText() or "" end)
    local ml = UI.Label(p, 10, UI.MUTED, "OUTLINE")
    ml:SetPoint("TOPLEFT", p, "TOPLEFT", x, -112)
    ml:SetText("MEET AT")
    mine.meet = editBox(p, "Dungeons_Meet", WIN_W - x - 18, MEET_MAX)
    mine.meet:SetPoint("TOPLEFT", p, "TOPLEFT", x, -126)
    mine.meet:SetScript("OnTextChanged", function() db().prefs.meet = this:GetText() or "" end)
    local hint = UI.Label(p, 10, UI.MUTED)
    hint:SetPoint("TOPLEFT", p, "TOPLEFT", x, -152)
    hint:SetWidth(WIN_W - x - 18)
    hint:SetText("Your listing lasts 30 minutes and renews while you play. Nobody joins until you invite them.")
    mine.listBtn = UI.Button(p, "List me", 100, 22, function()
        if D:List() then W.Print("Dungeons: you're listed. Players who fit will find you on the board.") end
    end)
    mine.listBtn:SetPoint("TOPLEFT", p, "TOPLEFT", x, -206)
    mine.unlistBtn = UI.Button(p, "Remove", 80, 22, function() D:Unlist() end)
    mine.unlistBtn:SetPoint("LEFT", mine.listBtn, "RIGHT", 6, 0)

    local rl = UI.Label(p, 10, UI.MUTED, "OUTLINE")
    rl:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -296)
    rl:SetText("ASKING TO JOIN YOU")
    local rinset = CreateFrame("Frame", nil, p)
    UI.Skin(rinset, "inset")
    rinset:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -310)
    rinset:SetWidth(WIN_W - 16)
    rinset:SetHeight(76)
    mine.reqs = UI.ScrollList(rinset, { width = WIN_W - 20, height = 72, rowHeight = 24,
        build = function(row, i)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetWidth(16)
            row.icon:SetHeight(16)
            row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.text = UI.Label(row, 10, { 1, 1, 1 })
            row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
            row.text:SetWidth(WIN_W - 190)
            row.decline = UI.Button(row, "Decline", 60, 18, function() D:DeclineRequest(row.index) end)
            row.decline:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.invite = UI.Button(row, "Invite", 60, 18, function() D:InviteRequest(row.index) end)
            row.invite:SetPoint("RIGHT", row.decline, "LEFT", -3, 0)
            setglobal("Dungeons_Request" .. i, row)
        end,
        update = function(row, r, index)
            row.index = index
            roleTexture(row.icon, r.role)
            row.text:SetText("|c" .. classHex(r.class) .. r.name .. "|r  " .. r.level .. " " .. (CLASS_NAME[r.class] or "")
                .. ", " .. ROLES[r.role].word .. "  |cffffd100" .. (r.dungeon and r.dungeon.name or "") .. "|r  |cff9da3b4" .. ago(r.at) .. "|r")
            row.invite:SetText(r.invited and "Invited" or "Invite")
        end,
    })
    mine.reqs:SetPoint("TOPLEFT", rinset, "TOPLEFT", 2, -2)
    mine.noReqs = UI.Label(rinset, 10, UI.MUTED)
    mine.noReqs:SetPoint("CENTER", rinset, "CENTER", 0, 0)
    mine.noReqs:SetText("When someone asks to join, they show up here with an Invite button.")
    return mine
end

local function buildRecent(p)
    local rec = {}
    local cap = UI.Label(p, 10, UI.MUTED)
    cap:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -2)
    cap:SetWidth(WIN_W - 30)
    cap:SetText("People you grouped with lately. Invite them again, or endorse the ones who made the run good.")
    local inset = CreateFrame("Frame", nil, p)
    UI.Skin(inset, "inset")
    inset:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -20)
    inset:SetWidth(WIN_W - 16)
    inset:SetHeight(364)
    rec.list = UI.ScrollList(inset, { width = WIN_W - 20, height = 360, rowHeight = 30,
        build = function(row, i)
            row.name = UI.Label(row, 11, { 1, 1, 1 }, "OUTLINE")
            row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -3)
            row.star = row:CreateTexture(nil, "ARTWORK")
            row.star:SetWidth(12)
            row.star:SetHeight(12)
            row.star:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
            starTexture(row.star)
            row.stars = UI.Label(row, 10, UI.ACCENT)
            row.stars:SetPoint("LEFT", row.star, "RIGHT", 1, 0)
            row.info = UI.Label(row, 10, UI.MUTED)
            row.info:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -17)
            row.endorse = UI.Button(row, "Endorse", 70, 18, function() if row.item then D:Endorse(row.item.name) end end)
            row.endorse:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.invite = UI.Button(row, "Invite", 56, 18, function()
                if row.item then D.groupDungeon = row.item.dungeon; InviteByName(row.item.name) end
            end)
            row.invite:SetPoint("RIGHT", row.endorse, "LEFT", -3, 0)
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(row)
            hl:SetTexture(1, 0.82, 0, 0.06)
            setglobal("Dungeons_Recent" .. i, row)
        end,
        update = function(row, r)
            row.name:SetText("|c" .. classHex(r.class) .. r.name .. "|r  |cffc8ccd6" .. (r.level or "?") .. " " .. (CLASS_NAME[r.class or ""] or "") .. "|r")
            local e = D:EndorseCount(r.name)
            if e > 0 then row.star:Show(); row.stars:SetText(tostring(e)) else row.star:Hide(); row.stars:SetText("") end
            local d = r.dungeon and D.BY_KEY[r.dungeon]
            row.info:SetText((d and d.name or "Grouped") .. "  " .. DOT .. "  " .. ago(r.at))
            if r.endorsed then row.endorse:SetText("Endorsed") else row.endorse:SetText("Endorse") end
            if D:CanEndorse(r) then row.endorse:Enable() else row.endorse:Disable() end
            if ignored(r.name) then row.invite:Disable() else row.invite:Enable() end
        end,
    })
    rec.list:SetPoint("TOPLEFT", inset, "TOPLEFT", 2, -2)
    rec.empty = UI.Label(inset, 11, UI.MUTED)
    rec.empty:SetPoint("CENTER", inset, "CENTER", 0, 0)
    rec.empty:SetText("Nobody yet. Group up and the people you run with appear here.")
    return rec
end

local sheet
local function buildWindow()
    if win then return win end
    win = UI.Window("Dungeons_Frame", { classicFrame = true, width = WIN_W, height = WIN_H, title = "Dungeons",
        icon = "Interface\\Icons\\INV_Misc_Key_03", point = { "CENTER", UIParent, "CENTER", -40, 40 }, skin = true })
    win:SetFrameStrata("HIGH")
    tinsert(UISpecialFrames, "Dungeons_Frame")
    win:Hide()

    local gear = UI.GearButton(win, function() sheet:Toggle() end, 14)
    gear:SetPoint("RIGHT", win.titleBar, "RIGHT", -22, 0)

    D.tabs = UI.Tabs(win, {
        tabs = { { key = "browse", label = "Browse" }, { key = "mine", label = "My Listing" }, { key = "recent", label = "Recent" } },
        onSelect = function(key) D:ShowPage(key) end,
        skin = true,
    })
    D.tabs:SetPoint("TOPLEFT", win, "TOPLEFT", 8, -28)

    for _, k in ipairs({ "browse", "mine", "recent" }) do
        local p = CreateFrame("Frame", nil, win)
        p:SetPoint("TOPLEFT", win, "TOPLEFT", 8, -54)
        p:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -8, 8)
        p:SetWidth(WIN_W - 16)
        p:SetHeight(WIN_H - 62)
        p:Hide()
        pages[k] = p
    end
    pages.browse:Show()
    D.browser = D:CreateBrowser(pages.browse, { width = WIN_W - 16, height = WIN_H - 62, travel = true, name = "Dungeons_Board" })
    D.browser.frame:SetPoint("TOPLEFT", pages.browse, "TOPLEFT", 0, 0)
    D.mine = buildMine(pages.mine)
    D.recent = buildRecent(pages.recent)

    sheet = UI.Sheet(win, { title = "Dungeons settings", width = 230 })
    sheet:AddSwitch("Join request toasts", "A banner when someone asks to join you or endorses you.",
        function() return setting("requestToasts", true) end, function(v) W:Settings(ID).requestToasts = v end)
    sheet:AddSwitch("Renew while active", "Keep your listing up while you play; it lapses 30 minutes after you go idle.",
        function() return setting("autoRenew", true) end, function(v) W:Settings(ID).autoRenew = v end)
    sheet:AddSwitch("Listings in tooltips", "Mouse over a listed player to see what they're looking for.",
        function() return setting("showInTooltip", true) end, function(v) W:Settings(ID).showInTooltip = v end)
    sheet:AddSwitch("New listings in chat", "A chat line when someone lists for a dungeon.",
        function() return setting("announceListings", false) end, function(v) W:Settings(ID).announceListings = v end)
    D.sheet = sheet

    win:SetScript("OnShow", function()
        D:AskWho(false)
        D:Refresh()
    end)
    win:SetScript("OnHide", function() if sheet then sheet:Hide() end end)
    return win
end

function D:ShowPage(key)
    buildWindow()
    for k, p in pairs(pages) do if k == key then p:Show() else p:Hide() end end
    self.page = key
    if self.tabs:Selected() ~= key then self.tabs:Select(key, true) end
    if key == "mine" then self.tabs:SetUnread("mine", false) end
    self:Refresh()
end

function D:Show(page)
    if not W:IsActive(ID) then W.Print("Dungeons is switched off. Turn it on in /addons.") return end
    buildWindow()
    win:Show()
    self:ShowPage(page or self.page or "browse")
end

function D:Toggle(page)
    buildWindow()
    if win:IsShown() and (not page or page == self.page) then win:Hide() else self:Show(page) end
end

function D:AskWho(force)
    if not force and self.askedAt and GetTime() - self.askedAt < 120 then return end
    if self.askedAt and GetTime() - self.askedAt < REFRESH_GAP then return end
    self.askedAt = GetTime()
    send("?L", "?L")
end

local function refreshMine()
    local m = D.mine
    local l = D:MyListing()
    local roles = prefRoles()
    local grouped = inGroup()
    if l then
        local left = D:TimeLeft()
        local n = 0
        for _ in pairs(l.dungeons) do n = n + 1 end
        m.status:SetText("|cff40ff40Listed|r for " .. n .. " dungeon" .. (n == 1 and "" or "s") .. " as " .. rolesText(l.roles, " / ")
            .. "  |cff9da3b4" .. DOT .. "  " .. math.max(1, math.ceil(left / 60)) .. " min left|r")
        m.listBtn:SetText("Update")
        m.unlistBtn:Show()
    else
        m.status:SetText(grouped and (isLeader() and "List your group so players can ask to join." or "Only your group leader can list the group.")
            or "Not listed. Pick your role and dungeons, then List me.")
        m.listBtn:SetText(grouped and "List group" or "List me")
        m.unlistBtn:Hide()
    end
    m.rolesLabel:SetText(grouped and "ROLES YOUR GROUP NEEDS" or "YOUR ROLE")
    local ok = D.CLASS_ROLES[myClass()] or {}
    for k, btn in pairs(m.roles) do
        local can = grouped or ok[k]
        if roles[k] and can then
            btn:SetBackdropBorderColor(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 1)
            btn.label:SetTextColor(1, 0.85, 0.3)
            btn.icon:SetAlpha(1)
        else
            btn:SetBackdropBorderColor(UI.EDGE[1], UI.EDGE[2], UI.EDGE[3], 1)
            btn.label:SetTextColor(can and 0.8 or 0.4, can and 0.8 or 0.4, can and 0.85 or 0.45)
            btn.icon:SetAlpha(can and 0.55 or 0.2)
        end
    end
    local lvl = UnitLevel("player") or 1
    local items = {}
    for _, d in ipairs(D.LIST) do if m.all or D.Fits(d, lvl) or db().prefs.dungeons[d.key] then tinsert(items, d) end end
    m.list:SetItems(items)
    m.dlabel:SetText(m.all and "EVERY DUNGEON" or ("DUNGEONS FOR LEVEL " .. lvl))
    m.showAll:SetText(m.all and "Fits me" or "Show all")
    local p = db().prefs
    if not m.note.loaded then m.note.loaded = true; m.note:SetText(p.note or ""); m.meet:SetText(p.meet or "") end
    m.reqs:SetItems(D.requests)
    if getn(D.requests) == 0 then m.noReqs:Show() else m.noReqs:Hide() end
end

function D:Refresh()
    for _, b in ipairs(self.browsers) do
        if b.frame:IsVisible() then self:RefreshBrowser(b) end
    end
    if not win or not win:IsShown() then return end
    if self.page == "mine" then refreshMine()
    elseif self.page == "recent" then
        self.recent.list:SetItems(db().recent)
        if getn(db().recent) == 0 then self.recent.empty:Show() else self.recent.empty:Hide() end
    end
end

-- -- Tooltips on players in the world ---------------------------------------------------------------------------------

local function decorateTooltip()
    if not W:IsActive(ID) or not setting("showInTooltip", true) then return end
    if not UnitIsPlayer or not UnitIsPlayer("mouseover") then return end
    local name = UnitName("mouseover")
    local l = name and D.listings[name]
    if not l or l.own or ignored(name) then return end
    GameTooltip:AddLine((l.kind == "g" and "Group looking for " or "Looking for ") .. D:DungeonText(l, 2)
        .. " (" .. rolesText(l.roles) .. ")", 0.25, 0.75, 1, 1)
    GameTooltip:Show()
end

-- -- Demo listings (/wnl demo) ----------------------------------------------------------------------------------------

local DEMO = {
    { "Brakkus", "g", "h,d", 22, "WARRIOR", "dm,wc", "Need a healer, then we go", "Moonbrook inn", "Westfall", 3, 6 },
    { "Ilyndra", "p", "d", 21, "MAGE", "dm,sfk", "Happy to learn the runs", "", "Elwynn Forest", 1, 2 },
    { "Thessaly", "p", "h", 19, "PRIEST", "wc,dm", "Holy, no rush", "", "The Barrens", 1, 11 },
    { "Orlen", "g", "t", 35, "PALADIN", "smlib,smarm", "Library then Armory", "Monastery gate", "Tirisfal Glades", 4, 0 },
    { "Saria", "p", "t,d", 58, "DRUID", "brd,lbrs,ubrs", "Feral, have the key", "", "Burning Steppes", 1, 23 },
}
local demoOn = false
local function demo(on)
    if on == demoOn then return end
    demoOn = on
    for name, l in pairs(D.listings) do if l.demo then D.listings[name] = nil end end
    if on then
        for i, x in ipairs(DEMO) do
            local roles, dungeons = {}, {}
            for _, k in ipairs((W.Split(x[3], ","))) do roles[k] = true end
            for _, k in ipairs((W.Split(x[6], ","))) do dungeons[k] = true end
            D.listings[x[1]] = { name = x[1], kind = x[2], roles = roles, level = x[4], class = x[5], dungeons = dungeons,
                note = x[7], meet = x[8], zone = x[9], size = x[10], presence = "", endorse = x[11], t = GetTime() - i * 60, demo = true }
        end
    end
    D:Refresh()
end

-- -- Events ------------------------------------------------------------------------------------------------------------

local ev = CreateFrame("Frame", "Dungeons_Events")
ev:RegisterEvent("VARIABLES_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_CHANNEL")
ev:RegisterEvent("CHAT_MSG_WHISPER")
ev:RegisterEvent("CHAT_MSG_SYSTEM")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:RegisterEvent("RAID_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
local joinAt, acc, lastPos = nil, 0, ""
ev:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        db()
        D.lastActive = now()
    elseif event == "PLAYER_ENTERING_WORLD" then
        joinAt = GetTime() + JOIN_DELAY
        D.lastActive = now()
        D:StoreOwn()
    elseif event == "CHAT_MSG_CHANNEL" then
        if strfind(strlower(arg9 or arg4 or ""), strlower(CHANNEL), 1, true) and W:IsActive(ID) then D:Receive(arg1, arg2) end
    elseif event == "CHAT_MSG_WHISPER" then
        if W:IsActive(ID) then D:OnWhisper(arg1, arg2) end
    elseif event == "CHAT_MSG_SYSTEM" then
        -- the stock /afk line: you stop counting as active
        if arg1 and strfind(arg1, "^You are now AFK") then D.lastActive = now() - LISTING_LIFE + 5 * 60 end
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        D:ScanGroup()
        if D:MyListing() and inGroup() and not isLeader() then D:Unlist(false, "Dungeons: you joined a group, so your listing is removed.") end
    elseif event == "PLAYER_LEVEL_UP" then
        D.lastActive = now()
        if D:MyListing() then D:Broadcast() end
        D:Refresh()
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_TARGET_CHANGED" then
        D.lastActive = now()
        if event == "ZONE_CHANGED_NEW_AREA" and inGroup() then D:ScanGroup() end
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        decorateTooltip()
    end
end)

ev:SetScript("OnUpdate", function()
    flush(arg1)
    acc = acc + arg1
    if acc < 1 then return end
    acc = 0
    if not W:IsActive(ID) then return end
    local t = GetTime()
    if joinAt and t >= joinAt then
        joinAt = nil
        joinOpen = true
        join()
        if D:MyListing() then D:Broadcast() end
    end
    -- moving counts as being active
    local x, y = GetPlayerMapPosition("player")
    local pos = floor((x or 0) * 1000) .. "," .. floor((y or 0) * 1000)
    if pos ~= lastPos then lastPos = pos; D.lastActive = now() end
    if D:MyListing() then
        if D:TimeLeft() <= 0 then
            D:Unlist(false, "Dungeons: your listing ran out after 30 minutes away. /lfg to list again.")
        elseif t - lastBroadcast > RENEW_EVERY then
            D:Broadcast()
        end
    end
    if D.replyAt and t >= D.replyAt then D.replyAt = nil; D:Broadcast() end
    D:Expire()
    demo(W.demoRunning and true or false)
    if win and win:IsShown() and D.page == "mine" then refreshMine() end
end)

-- -- Registration -----------------------------------------------------------------------------------------------------------

W:RegisterSchema(ID, {
    title = "Dungeons - Group Finder",
    icon = "Interface\\Icons\\INV_Misc_Key_03",
    desc = "A board of players and groups looking for each dungeon and raid. Ask to join or invite with one click; nobody is moved or grouped without a normal invite. /lfg",
    defaults = { requestToasts = true, autoRenew = true, showInTooltip = true, announceListings = false, sounds = true },
    options = {
        { key = "requestToasts", label = "Join request toasts", sub = "A banner when someone asks to join you or endorses you." },
        { key = "autoRenew", label = "Renew while active", sub = "Keep your listing up while you play; it lapses 30 minutes after you go idle." },
        { key = "showInTooltip", label = "Listings in tooltips", sub = "Mouse over a listed player to see what they're looking for." },
        { key = "announceListings", label = "New listings in chat", sub = "A chat line when someone lists for a dungeon." },
        { key = "sounds", label = "Request sound", sub = "Play the invite sound when someone asks to join." },
    },
})

W:RegisterAddon(ID, function(active)
    if not active then
        if win then win:Hide() end
        if db().listed then D:Unlist(true) end
    end
end)

SLASH_DUNGEONS1 = "/lfg"
SLASH_DUNGEONS2 = "/dungeons"
SlashCmdList["DUNGEONS"] = function(msg)
    msg = strlower(W.Trim(msg))
    if not W:IsActive(ID) then W.Print("Dungeons is switched off. Turn it on in /addons.") return end
    if msg == "list" or msg == "me" or msg == "mine" then return D:Show("mine") end
    if msg == "recent" then return D:Show("recent") end
    if msg == "browse" then return D:Show("browse") end
    if msg == "off" or msg == "unlist" or msg == "remove" then
        if D:MyListing() then D:Unlist() else W.Print("Dungeons: you're not listed.") end
        return
    end
    if msg == "help" then
        W.Print("/lfg  the board   " .. DOT .. "  /lfg list  your listing   " .. DOT .. "  /lfg recent   " .. DOT .. "  /lfg off  remove your listing")
        return
    end
    D:Toggle()
end
