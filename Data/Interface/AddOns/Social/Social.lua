--[[
    Social.lua  -  friends, guild, group, /who, ignore and recent people in one window.

    Pressing O (or the Socials button, anything that calls ToggleFriendsFrame) opens this window
    instead of the stock Friends frame; the stock one stays one click away ("Blizzard's window")
    and comes back entirely when "Open with O" is switched off.

      Friends   online first, class colours, level, zone, Persona status, presence, a private
                note per friend, search and sort; offline friends show when you last saw them
      Guild     the roster with ranks, notes and last seen, the message of the day, and
                invites with a rank preset for officers (promoted step by step as the API allows)
      Group     your party or raid with roles, ready check and loot method, plus the Dungeons
                board when Dungeons is loaded
      Who       /who with level, class, zone and guild filters, sorting, Whisper and Invite
      Ignore    one ignore list with a note, shared by chat, Persona, Dungeons and anything else
                through WenillaCore.Ignore (IsIgnored, Add, Remove, Note, List)
      Recent    people you grouped, traded or duelled with lately

    Toasts when a friend or guild mate comes online or levels up (mute anyone from their menu);
    private notes and colour tags show in tooltips and on names in chat; your Away / Busy /
    Looking for group presence reaches other Classic+ players over a hidden channel (OWSocial):
        #S <presence> <level>      my presence and level (on login, change, level up, every 15 min)
        ?S                         "send me yours" (answered after a random pause, once a minute)

        /social [friends|guild|group|who|ignore|recent]     O toggles, 1-6 switch tabs (hover)

    Lua 5.0 rules (1.12.1 client): no '#', no '%' operator, handlers read this/event/arg1..arg9.
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Social"
local CHANNEL = "OWSocial"

Social = Social or {}
local S = Social
S.version = "1.0.0"

local strfind, strsub, strgsub, strlen, strlower, strupper = string.find, string.sub, string.gsub, string.len, string.lower, string.upper
local tinsert, tremove, getn = table.insert, table.remove, table.getn
local floor = math.floor
local DOT = "\194\183"

local TABS = {
    { key = "friends", label = "Friends" }, { key = "guild", label = "Guild" }, { key = "group", label = "Group" },
    { key = "who", label = "Who" }, { key = "ignore", label = "Ignore" }, { key = "recent", label = "Recent" },
}
local STOCK_TAB = { [1] = "friends", [2] = "who", [3] = "guild", [4] = "group" }
local PRESENCE = {
    { key = "", label = "Available", color = { 0.25, 1, 0.35 } },
    { key = "away", label = "Away", color = { 1, 0.82, 0.25 } },
    { key = "busy", label = "Busy", color = { 1, 0.35, 0.25 } },
    { key = "lfg", label = "Looking for group", color = { 0.25, 0.75, 1 } },
}
local PRESENCE_BY = {}
for _, p in ipairs(PRESENCE) do PRESENCE_BY[p.key] = p end
local TAGS = {
    { key = "gold", label = "Gold", hex = "ffffd100" }, { key = "green", label = "Green", hex = "ff40e070" },
    { key = "blue", label = "Blue", hex = "ff40a8ff" }, { key = "purple", label = "Purple", hex = "ffc080ff" },
    { key = "red", label = "Red", hex = "ffff5848" },
}
local TAG_HEX = {}
for _, t in ipairs(TAGS) do TAG_HEX[t.key] = t.hex end
local CLASS_NAME = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
    SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}
local CLASS_TOKEN = {}
for k, v in pairs(CLASS_NAME) do CLASS_TOKEN[strlower(v)] = k end
local CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local LOOT = {
    { "group", "Group loot" }, { "needbeforegreed", "Need before greed" }, { "freeforall", "Free for all" },
    { "roundrobin", "Round robin" }, { "master", "Master looter" },
}
local WHO_GAP = 5
local SEND_GAP = 0.7
local JOIN_DELAY = 10
local ICON = "Interface\\Icons\\INV_Misc_Note_01"
local PORTRAIT = "Interface\\FriendsFrame\\FriendsFrameScrollIcon"    -- the stock Social portrait

-- -- Helpers ---------------------------------------------------------------------------------------

local function me() return UnitName("player") or "?" end
local function now() return time and time() or 0 end
local function realm() return GetRealmName and GetRealmName() or "?" end
local function blank(s) return not s or s == "" end
local function setting(key, default) return W:Setting(ID, key, default) end
local function clean(s) local r = strgsub(s or "", "|", "||") return r end
local function tokenOf(class) return CLASS_TOKEN[strlower(class or "")] or (CLASS_NAME[strupper(class or "")] and strupper(class)) end

local function classHex(token)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token or ""]
    local r, g, b
    if c then r, g, b = c.r, c.g, c.b else r, g, b = UI.ClassColor(token) end
    return string.format("ff%02x%02x%02x", floor(r * 255), floor(g * 255), floor(b * 255))
end

local function ago(t)
    if not t or t == 0 then return nil end
    local d = now() - t
    if d < 120 then return "just now" end
    if d < 3600 then return floor(d / 60) .. " min ago" end
    if d < 86400 then local h = floor(d / 3600) return h .. " hour" .. (h == 1 and "" or "s") .. " ago" end
    local n = floor(d / 86400)
    return n .. " day" .. (n == 1 and "" or "s") .. " ago"
end
S.Ago = ago

local function zoneIndex(zone)
    if not GetMapZones or blank(zone) then return nil end
    for c = 1, 2 do
        local zones = { GetMapZones(c) }
        for i, z in ipairs(zones) do if z == zone then return c, i end end
    end
end

-- -- Saved data ------------------------------------------------------------------------------------
-- Social_DB.people[realm][name]   { note, tag, mute, seen, level, class } (all your characters)
-- Social_DB.chars[realm-name]     { ignore = { name = { note, at, g } }, recent = {...}, presence }

local function db()
    if type(Social_DB) ~= "table" then Social_DB = {} end
    local d = Social_DB
    d.people = d.people or {}
    d.people[realm()] = d.people[realm()] or {}
    d.chars = d.chars or {}
    local key = realm() .. "-" .. me()
    local c = d.chars[key]
    if not c then c = {} d.chars[key] = c end
    c.ignore = c.ignore or {}
    c.recent = c.recent or {}
    c.presence = c.presence or ""
    return d, c
end
local function people() local d = db() return d.people[realm()] end
local function char() local _, c = db() return c end

function S:Person(name, create)
    local p = people()[name]
    if not p and create then p = {} people()[name] = p end
    return p
end

-- -- The shared ignore list (WenillaCore.Ignore) -------------------------------------------------------
-- Our list carries a note and a date; the stock list (the server blocks chat from it) is kept in
-- step: Add also ignores in the game, Remove un-ignores, and /unignore in chat removes ours too.

local Ignore = {}

local function gameIgnored(name)
    if not GetNumIgnores then return false end
    for i = 1, GetNumIgnores() do if GetIgnoreName(i) == name then return true end end
    return false
end

local function fixName(name)
    name = W.Trim(name or "")
    if name == "" then return nil end
    return strupper(strsub(name, 1, 1)) .. strlower(strsub(name, 2))
end

-- accept both Ignore.IsIgnored(name) and Ignore:IsIgnored(name)
function Ignore.IsIgnored(a, b)
    local name = (a == Ignore) and b or a
    if blank(name) then return false end
    if type(Social_DB) == "table" then
        local c = char()
        if c.ignore[name] then return true end
    end
    return gameIgnored(name)
end

function Ignore.Add(a, b, c)
    local name, note = a, b
    if a == Ignore then name, note = b, c end
    name = fixName(name)
    if not name or name == me() then return false end
    local list = char().ignore
    list[name] = { note = W.Trim(note or ""), at = now() }
    if not gameIgnored(name) and AddIgnore then AddIgnore(name) end
    list[name].g = true     -- in the stock list too; a failed add (no such player) drops out on the next sync
    S:Changed()
    return true
end

function Ignore.Remove(a, b)
    local name = fixName((a == Ignore) and b or a)
    if not name then return false end
    char().ignore[name] = nil
    if gameIgnored(name) and DelIgnore then DelIgnore(name) end
    S:Changed()
    return true
end

function Ignore.Note(a, b)
    local name = (a == Ignore) and b or a
    local e = name and type(Social_DB) == "table" and char().ignore[name]
    return e and e.note or nil
end

-- every ignored player: { name, note, at }, ours and the stock list's, by name
function Ignore.List()
    local out, seen = {}, {}
    for name, e in pairs(char().ignore) do
        tinsert(out, { name = name, note = e.note or "", at = e.at })
        seen[name] = true
    end
    if GetNumIgnores then
        for i = 1, GetNumIgnores() do
            local n = GetIgnoreName(i)
            if n and not seen[n] then tinsert(out, { name = n, note = "", at = nil }) seen[n] = true end
        end
    end
    table.sort(out, function(x, y) return x.name < y.name end)
    return out
end

-- the stock list changed (/ignore, /unignore): keep ours in step
function Ignore.Sync()
    local list = char().ignore
    for name, e in pairs(list) do
        local inGame = gameIgnored(name)
        if e.g and not inGame then list[name] = nil       -- un-ignored in the game
        elseif inGame then e.g = true end
    end
end

W.Ignore = Ignore
S.Ignore = Ignore

-- the list changed: every window that filters by it redraws
function S:Changed()
    self:Refresh()
    if Dungeons and Dungeons.Refresh then Dungeons:Refresh() end
end

-- chat from players on our list never reaches a chat window
local CHAT_FROM = {
    CHAT_MSG_SAY = true, CHAT_MSG_YELL = true, CHAT_MSG_WHISPER = true, CHAT_MSG_EMOTE = true, CHAT_MSG_TEXT_EMOTE = true,
    CHAT_MSG_CHANNEL = true, CHAT_MSG_PARTY = true, CHAT_MSG_RAID = true, CHAT_MSG_GUILD = true, CHAT_MSG_OFFICER = true,
}
tinsert(W.chatFilters, function(ev)
    if CHAT_FROM[ev] and arg2 and W:IsActive(ID) and type(Social_DB) == "table" and char().ignore[arg2] then return true end
    if ev ~= "CHAT_MSG_CHANNEL" and ev ~= "CHAT_MSG_CHANNEL_NOTICE"
        and ev ~= "CHAT_MSG_CHANNEL_JOIN" and ev ~= "CHAT_MSG_CHANNEL_LEAVE" then return false end
    return strfind(strlower(arg9 or arg4 or ""), strlower(CHANNEL), 1, true) ~= nil
end)

-- -- Presence channel ------------------------------------------------------------------------------------

S.presence = {}     -- name -> { p, level, t }
local outbox, sinceSend = {}, 0

function S:MyPresence() return (type(Social_DB) == "table" and char().presence) or "" end

local function channelId()
    local id = GetChannelName and GetChannelName(CHANNEL)
    if id and id > 0 then return id end
end
local lastJoin = -100
-- Opened JOIN_DELAY after entering the world, so a line queued before then (flush) can't
-- join early and take one of the stock channels' numbers (General, Trade, LocalDefense, ...).
local joinOpen = false
local function join()
    if channelId() or not JoinChannelByName or not joinOpen or GetTime() - lastJoin < 15 then return end
    lastJoin = GetTime()
    JoinChannelByName(CHANNEL)
    for i = 1, (NUM_CHAT_WINDOWS or 7) do
        local cf = getglobal("ChatFrame" .. i)
        if cf and ChatFrame_RemoveChannel then ChatFrame_RemoveChannel(cf, CHANNEL) end
    end
end
local function send(line)
    local kind = strsub(line, 1, 2)
    local keep = {}
    for _, l in ipairs(outbox) do if strsub(l, 1, 2) ~= kind then tinsert(keep, l) end end
    outbox = keep
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

local lastAnnounce = -1000
function S:Announce()
    if not W:IsActive(ID) then return end
    local p = self:MyPresence()
    send("#S " .. (p == "" and "on" or p) .. " " .. (UnitLevel("player") or 1))
    lastAnnounce = GetTime()
end

function S:SetPresence(key)
    if not PRESENCE_BY[key or ""] then return end
    char().presence = key
    self:Announce()
    if Dungeons and Dungeons.MyListing and Dungeons:MyListing() then Dungeons:Broadcast() end
    W.Print("Social: you're now " .. PRESENCE_BY[key].label .. ".")
    self:Refresh()
end

function S:CyclePresence(back)
    local cur = self:MyPresence()
    local i = 1
    for j, p in ipairs(PRESENCE) do if p.key == cur then i = j end end
    i = i + (back and -1 or 1)
    if i > getn(PRESENCE) then i = 1 elseif i < 1 then i = getn(PRESENCE) end
    self:SetPresence(PRESENCE[i].key)
end

local friendSet, guildSet = {}, {}

function S:Receive(msg, sender)
    if blank(msg) or blank(sender) or sender == me() or Ignore.IsIgnored(sender) then return end
    local kind = strsub(msg, 1, 2)
    if kind == "#S" then
        local _, _, p, lvl = strfind(msg, "^#S (%a+) (%d+)")
        if not p then return end
        if p == "on" then p = "" end
        if not PRESENCE_BY[p] then p = "" end
        lvl = tonumber(lvl)
        self.presence[sender] = { p = p, level = lvl, t = GetTime() }
        if lvl and lvl >= 1 and lvl <= 60 then self:SawLevel(sender, lvl) end
        self:Refresh()
    elseif kind == "?S" then
        if GetTime() - lastAnnounce > 60 then self.replyAt = GetTime() + 1 + math.random() * 5 end
    end
end

-- their presence: ours from the channel, else the stock <AFK> / <DND> flag from the friends list
function S:PresenceOf(name)
    local p = self.presence[name]
    if p and GetTime() - p.t < 20 * 60 and p.p ~= "" then return p.p end
    local f = friendSet[name]
    if f and f.status then
        if strfind(f.status, "AFK") then return "away" end
        if strfind(f.status, "DND") then return "busy" end
    end
    return ""
end
function S:Presence(name) return self:PresenceOf(name) end

-- -- Toasts --------------------------------------------------------------------------------------------------

local toasted = {}

function S:Muted(name)
    local p = self:Person(name)
    return p and p.mute
end

function S:Toast(name, kind, title, text, class)
    if not W:IsActive(ID) or self:Muted(name) or Ignore.IsIgnored(name) then return end
    local key = name .. ":" .. kind
    if toasted[key] and GetTime() - toasted[key] < 60 then return end
    toasted[key] = GetTime()
    local token = class or (self:Person(name) or {}).class
    UI.Toast({
        icon = UI.CLASS_ICONS[token or ""] or ICON, title = title, text = text,
        color = strfind(kind, "^level") and { 1, 0.82, 0 } or { 0.3, 0.95, 0.45 },
        sound = setting("toastSound", true) and "FriendJoinGame" or nil,
        onClick = function() S.askedAt = GetTime(); S:Show(guildSet[name] and not friendSet[name] and "guild" or "friends") end,
    })
end

function S:CameOnline(name)
    local f, g = friendSet[name], guildSet[name]
    if f and setting("toastFriends", true) then
        local where = (f.zone and f.zone ~= "") and (DOT .. " " .. f.zone) or ""
        self:Toast(name, "online", name .. " is online", "Level " .. (f.level or "?") .. " " .. (CLASS_NAME[f.token or ""] or "") .. " " .. where, f.token)
    elseif g and setting("toastGuild", true) then
        self:Toast(name, "online", name .. " is online", "Guild " .. DOT .. " " .. (g.rank or ""), g.token)
    end
end

-- a level we saw for someone; a higher one than last time is a level up worth a toast
function S:SawLevel(name, level)
    if not level or level < 1 then return end
    local p = self:Person(name, friendSet[name] or guildSet[name])
    if not p then return end
    local old = p.level
    p.level = level
    if old and level > old and (friendSet[name] or guildSet[name]) and setting("toastLevel", true) then
        self:Toast(name, "level" .. level, name .. " reached level " .. level .. "!", "Send them a congratulations whisper.")
    end
end

-- -- Friends ---------------------------------------------------------------------------------------------------

S.friends = {}
local friendsScanned = false

function S:ScanFriends()
    local list, set = {}, {}
    local n = GetNumFriends and GetNumFriends() or 0
    for i = 1, n do
        local name, level, class, zone, connected, status = GetFriendInfo(i)
        if name then
            local token = tokenOf(class)
            local f = { name = name, level = tonumber(level) or 0, class = class, token = token, zone = zone or "",
                online = connected and true or false, status = status or "", index = i }
            tinsert(list, f)
            set[name] = f
        end
    end
    local was = friendSet
    friendSet = set
    self.friends = list
    for _, f in ipairs(list) do
        local p = self:Person(f.name, true)
        if f.online then
            p.seen = now()
            if f.token then p.class = f.token end
            if friendsScanned and was[f.name] and not was[f.name].online then self:CameOnline(f.name) end
            if f.level > 0 then self:SawLevel(f.name, f.level) end
        end
    end
    friendsScanned = true
    self:Refresh()
end

function S:IsFriend(name) return friendSet[name] and true or false end

-- -- Guild ------------------------------------------------------------------------------------------------------

S.roster = {}
S.pendingRank = {}     -- name -> rankIndex wanted (0 = guild master)
local guildScanned = false

local function lastOnlineText(i, name)
    if GetGuildRosterLastOnline then
        local y, m, d, h = GetGuildRosterLastOnline(i)
        if y or m or d or h then
            y, m, d, h = y or 0, m or 0, d or 0, h or 0
            if y > 0 then return y .. " year" .. (y == 1 and "" or "s") .. " ago" end
            if m > 0 then return m .. " month" .. (m == 1 and "" or "s") .. " ago" end
            if d > 0 then return d .. " day" .. (d == 1 and "" or "s") .. " ago" end
            if h > 0 then return h .. " hour" .. (h == 1 and "" or "s") .. " ago" end
            return "less than an hour ago"
        end
    end
    local p = S:Person(name)
    return p and ago(p.seen) or nil
end

function S:ScanGuild()
    local list, set = {}, {}
    if IsInGuild and IsInGuild() and GetGuildRosterInfo then
        local n = GetNumGuildMembers(true) or 0
        for i = 1, n do
            local name, rank, rankIndex, level, class, zone, note, officernote, online = GetGuildRosterInfo(i)
            if name then
                local m = { name = name, rank = rank or "", rankIndex = rankIndex or 0, level = tonumber(level) or 0, class = class,
                    token = tokenOf(class), zone = zone or "", note = note or "", online = online and true or false, index = i }
                m.last = (not m.online) and lastOnlineText(i, name) or nil
                if Concord and Concord.GetProfessions then m.prof = Concord:GetProfessions(name) end
                tinsert(list, m)
                set[name] = m
            end
        end
    end
    local was = guildSet
    guildSet = set
    self.roster = list
    for _, m in ipairs(list) do
        if m.name ~= me() then
            local p = self:Person(m.name, true)
            if m.online then
                p.seen = now()
                if m.token then p.class = m.token end
                if guildScanned and was[m.name] and not was[m.name].online then self:CameOnline(m.name) end
                self:SawLevel(m.name, m.level)
            end
        end
        -- a rank preset for someone we invited: promote one step per roster update
        local want = self.pendingRank[m.name]
        if want then
            if m.rankIndex <= want.rank then
                self.pendingRank[m.name] = nil
                W.Print("Social: " .. m.name .. " joined the guild as " .. m.rank .. ".")
            elseif CanGuildPromote and CanGuildPromote() and want.tries < 10 then
                want.tries = want.tries + 1
                GuildPromoteByName(m.name)
            end
        end
    end
    guildScanned = true
    self:Refresh()
end

function S:IsGuildMate(name) return guildSet[name] and true or false end

-- invite to the guild; officers may pick the rank the newcomer should end up with
function S:GuildInvite(name, rankIndex)
    name = fixName(name)
    if not name or not (CanGuildInvite and CanGuildInvite()) then return false end
    GuildInviteByName(name)
    local lowest = (GuildControlGetNumRanks and GuildControlGetNumRanks() or 1) - 1
    if rankIndex and rankIndex < lowest then self.pendingRank[name] = { rank = rankIndex, tries = 0 } end
    if GuildRoster then GuildRoster() end
    return true
end

-- -- Recent people ---------------------------------------------------------------------------------------------------

function S:Remember(name, what, class, level)
    if blank(name) or name == me() or name == UNKNOWNOBJECT then return end
    local list = char().recent
    for i, r in ipairs(list) do
        if r.name == name then tremove(list, i) break end
    end
    tinsert(list, 1, { name = name, what = what, class = class, level = level, at = now(), zone = GetRealZoneText and GetRealZoneText() or "" })
    while getn(list) > 50 do tremove(list) end
    self:Refresh()
end

function S:ScanGroup()
    local r = GetNumRaidMembers and GetNumRaidMembers() or 0
    if r > 0 then
        for i = 1, r do
            local n, _, _, lvl, _, class = GetRaidRosterInfo(i)
            if n and n ~= me() then self:Remember(n, "Grouped", class, lvl) end
        end
    else
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) then
                local _, class = UnitClass(u)
                self:Remember(UnitName(u), "Grouped", class, UnitLevel(u))
            end
        end
    end
end

-- -- Who ------------------------------------------------------------------------------------------------------------------

S.who = { results = {}, sort = "name", class = 0 }

function S:WhoQuery()
    local w = self.whoUI
    local parts = {}
    local function add(prefix, box)
        local v = W.Trim(box:GetText() or "")
        if v ~= "" then tinsert(parts, prefix .. "-\"" .. strgsub(v, "\"", "") .. "\"") end
    end
    add("n", w.name)
    add("z", w.zone)
    add("g", w.guild)
    if self.who.class > 0 then tinsert(parts, "c-\"" .. CLASS_NAME[CLASS_ORDER[self.who.class]] .. "\"") end
    local lo, hi = tonumber(w.lo:GetText() or ""), tonumber(w.hi:GetText() or "")
    if lo or hi then
        lo, hi = lo or 1, hi or 60
        if lo > hi then lo, hi = hi, lo end
        tinsert(parts, lo .. "-" .. hi)
    end
    return table.concat(parts, " ")
end

function S:WhoWait()
    if not self.who.sentAt then return 0 end
    return math.max(0, WHO_GAP - (GetTime() - self.who.sentAt))
end

function S:SearchWho(query)
    if self:WhoWait() > 0 then return false end
    query = query or self:WhoQuery()
    self.who.sentAt = GetTime()
    self.who.pending = true
    self.who.query = query
    if SetWhoToUI then SetWhoToUI(1) end
    SendWho(query)
    self:Refresh()
    return true
end

function S:ReadWho()
    local out = {}
    local n = GetNumWhoResults and GetNumWhoResults() or 0
    for i = 1, n do
        local name, guild, level, race, class, zone = GetWhoInfo(i)
        if name and not Ignore.IsIgnored(name) then
            tinsert(out, { name = name, guild = guild or "", level = tonumber(level) or 0, race = race or "", class = class or "",
                token = tokenOf(class), zone = zone or "" })
        end
    end
    self.who.results = out
    self.who.pending = nil
    if SetWhoToUI then SetWhoToUI(0) end
    self:SortWho()
end

function S:SortWho(key)
    if key then
        if self.who.sort == key then self.who.desc = not self.who.desc else self.who.sort, self.who.desc = key, (key == "level") end
    end
    local k, desc = self.who.sort, self.who.desc
    table.sort(self.who.results, function(a, b)
        local x, y = a[k], b[k]
        if k ~= "level" then x, y = strlower(tostring(x)), strlower(tostring(y)) end
        if x == y then return a.name < b.name end
        if desc then return x > y end
        return x < y
    end)
    self:Refresh()
end

-- -- Actions ----------------------------------------------------------------------------------------------------------------

function S:Whisper(name)
    if ChatFrame_OpenChat then ChatFrame_OpenChat("/w " .. name .. " ") end
end
function S:Invite(name)
    if Ignore.IsIgnored(name) then return end
    InviteByName(name)
end
function S:ShowOnMap(zone)
    local c, z = zoneIndex(zone)
    if not c then W.Print("Social: no map for " .. (zone or "that zone") .. ".") return false end
    if WorldMapFrame and not WorldMapFrame:IsShown() then
        if ShowUIPanel then ShowUIPanel(WorldMapFrame) else WorldMapFrame:Show() end
    end
    SetMapZoom(c, z)
    return true
end
function S:ViewPersona(name)
    if Persona and Persona.ShowView then Persona.ShowView(name) end
end
function S:SetNote(name, note, tag)
    local p = self:Person(name, true)
    p.note = W.Trim(note or "")
    if tag ~= nil then p.tag = (tag ~= "" and TAG_HEX[tag]) and tag or nil end
    self:Refresh()
end
function S:ToggleMute(name)
    local p = self:Person(name, true)
    p.mute = (not p.mute) and true or nil
    W.Print("Social: " .. (p.mute and "no more" or "showing") .. " toasts for " .. name .. ".")
    self:Refresh()
end

-- -- Tooltips and chat names ---------------------------------------------------------------------------------------------

local function noteLine(name)
    local p = S:Person(name)
    if not p or (blank(p.note) and not p.tag) then return nil end
    local hex = TAG_HEX[p.tag or ""] or "ffd8d8e0"
    return "|c" .. hex .. (blank(p.note) and "Tagged" or ("Note: " .. clean(p.note))) .. "|r"
end

local function decorateTooltip()
    if not W:IsActive(ID) or not setting("notesInTooltips", true) then return end
    if not UnitIsPlayer or not UnitIsPlayer("mouseover") then return end
    local name = UnitName("mouseover")
    local line = name and noteLine(name)
    if not line then return end
    GameTooltip:AddLine(line, 1, 1, 1, 1)
    GameTooltip:Show()
end

-- "[Name]" in a chat line takes the colour tag you gave that player
local tagged = {}     -- name -> hex, rebuilt on change
function S:RebuildTags()
    tagged = {}
    for name, p in pairs(people()) do if p.tag and TAG_HEX[p.tag] then tagged[name] = TAG_HEX[p.tag] end end
end

local function colourNames(msg)
    if type(msg) ~= "string" or not next(tagged) or not W:IsActive(ID) or not setting("tagChatNames", true) then return msg end
    for name, hex in pairs(tagged) do
        if strfind(msg, "[" .. name .. "]", 1, true) then
            local pat = "%[" .. strgsub(name, "(%W)", "%%%1") .. "%]"
            msg = strgsub(msg, pat, "[|c" .. hex .. name .. "|r]")
        end
    end
    return msg
end

for i = 1, (NUM_CHAT_WINDOWS or 7) do
    local cf = getglobal("ChatFrame" .. i)
    if cf and cf.AddMessage then
        local orig = cf.AddMessage
        cf.AddMessage = function(self, msg, r, g, b, id) return orig(self, colourNames(msg), r, g, b, id) end
    end
end

-- -- Window ------------------------------------------------------------------------------------------------------------------

-- The original Friends frame look (UI.ClassicFrame), larger: pages sit in its marble body.
local EXTRA = 64                                  -- extra list height over the old 476-high window
local PAGE_W, PAGE_H = 500, 414 + EXTRA
local WIN_W, WIN_H = PAGE_W + 34, PAGE_H + 86
local win, pages, ui = nil, {}, {}
S.ui = ui

local function editBox(parent, name, width, maxLetters, placeholder)
    local e = UI.SearchBox(parent, { name = name, width = width, placeholder = placeholder })
    e:SetMaxLetters(maxLetters or 40)
    return e
end

local CLASSIC_INSET = UI.SKINS and UI.SKINS.classic and UI.SKINS.classic.inset
local function inset(parent, y, h)
    local f = CreateFrame("Frame", nil, parent)
    if CLASSIC_INSET then
        -- the stock list well: dark, with the grey tooltip edge
        f:SetBackdrop(CLASSIC_INSET)
        f:SetBackdropColor(0, 0, 0, 0.55)
        f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    else
        UI.Skin(f, "inset")
    end
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    f:SetWidth(PAGE_W)
    f:SetHeight(h)
    return f
end

local function hl(row)
    -- the stock Friends list highlight bar
    local t = row:CreateTexture(nil, "HIGHLIGHT")
    t:SetAllPoints(row)
    t:SetTexture("Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar")
    t:SetBlendMode("ADD")
end

-- An empty list gets a picture, not just a line: a round, dimmed emblem above the text.
local EMPTY_ART = {
    friends = "Interface\\Icons\\Spell_Holy_PrayerOfSpirit", who = "Interface\\Icons\\INV_Misc_Spyglass_02",
    ignore = "Interface\\Icons\\Spell_Holy_Silence", recent = "Interface\\Icons\\INV_Misc_PocketWatch_01",
}
-- SetPortraitToTexture by the texture's name (the browser engine takes the name, not the object);
-- falls back to a square SetTexture when neither works
local function roundPortrait(t, path)
    if SetPortraitToTexture and path then
        local n = t.GetName and t:GetName()
        if (n and pcall(SetPortraitToTexture, n, path)) or pcall(SetPortraitToTexture, t, path) then return true end
    end
    t:SetTexture(path)
end
local function emptyArt(box, label, key)
    local t = box:CreateTexture("Social_EmptyArt_" .. key, "ARTWORK")
    t:SetWidth(56)
    t:SetHeight(56)
    t:SetPoint("BOTTOM", label, "TOP", 0, 10)
    roundPortrait(t, EMPTY_ART[key])
    t:SetAlpha(0.55)
    local ring = box:CreateTexture(nil, "OVERLAY")
    ring:SetWidth(78)
    ring:SetHeight(78)
    ring:SetPoint("CENTER", t, "CENTER", 0, 0)
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetTexCoord(0, 0.6, 0, 0.6)
    ring:SetAlpha(0.8)
    t:Hide(); ring:Hide()
    return { t, ring }
end

local function nameText(name, token, online, level)
    local p = S:Person(name)
    local hex = (p and p.tag and TAG_HEX[p.tag]) or (online and token and classHex(token)) or (online and "ffffffff" or "ff8a8d96")
    return "|c" .. hex .. name .. "|r" .. ((online and S.LiveTag) and S:LiveTag(name) or "")
end

local function personMenu(anchor, name, opts)
    opts = opts or {}
    local p = S:Person(name) or {}
    local items = { { text = name, title = true } }
    tinsert(items, { text = "Whisper", func = function() S:Whisper(name) end, disabled = opts.offline })
    tinsert(items, { text = "Invite to group", func = function() S:Invite(name) end, disabled = opts.offline })
    if Persona and Persona.ShowView then tinsert(items, { text = "View Persona", func = function() S:ViewPersona(name) end }) end
    if opts.zone and opts.zone ~= "" then
        tinsert(items, { text = "Show " .. opts.zone .. " on the map", func = function() S:ShowOnMap(opts.zone) end })
    end
    tinsert(items, { text = "Note and colour tag", func = function() S:EditNote(name) end })
    tinsert(items, { text = p.mute and "Show their toasts" or "Mute their toasts", func = function() S:ToggleMute(name) end })
    if opts.friend then
        tinsert(items, { text = "Remove friend", color = { 1, 0.45, 0.4 }, func = function() RemoveFriend(name) end })
    elseif not S:IsFriend(name) then
        tinsert(items, { text = "Add friend", func = function() AddFriend(name) end })
    end
    if not Ignore.IsIgnored(name) then
        tinsert(items, { text = "Ignore", color = { 1, 0.45, 0.4 }, func = function() Ignore.Add(name, "") end })
    end
    if W.Report then tinsert(items, { text = "Report...", color = { 1, 0.45, 0.4 }, func = function() W.Report.Open(name, "social") end }) end
    S.menuFor = name
    return UI.Menu(anchor, items)
end
S.PersonMenu = personMenu

-- the note editor strip shared by every tab
local function buildNoteBar()
    local bar = CreateFrame("Frame", "Social_NoteBar", win)
    UI.Skin(bar, "raised")
    bar:SetPoint("BOTTOMLEFT", win.body or win, "BOTTOMLEFT", 0, 0)
    bar:SetWidth(PAGE_W)
    bar:SetHeight(50)
    bar:SetFrameLevel(win:GetFrameLevel() + 20)
    bar.title = UI.Label(bar, 10, UI.ACCENT, "OUTLINE")
    bar.title:SetPoint("TOPLEFT", bar, "TOPLEFT", 8, -6)
    bar.box = editBox(bar, "Social_NoteBox", 250, 80, "A private note only you see")
    bar.box:SetPoint("TOPLEFT", bar, "TOPLEFT", 8, -24)
    bar.swatches = {}
    local x = 266
    for i, t in ipairs(TAGS) do
        local key = t.key
        local sw = CreateFrame("Button", nil, bar)
        sw:SetWidth(14)
        sw:SetHeight(14)
        sw:SetPoint("TOPLEFT", bar, "TOPLEFT", x + (i - 1) * 17, -26)
        sw.tex = sw:CreateTexture(nil, "ARTWORK")
        sw.tex:SetAllPoints(sw)
        local hex = t.hex
        sw.tex:SetTexture(tonumber(strsub(hex, 3, 4), 16) / 255, tonumber(strsub(hex, 5, 6), 16) / 255, tonumber(strsub(hex, 7, 8), 16) / 255, 1)
        sw.ring = sw:CreateTexture(nil, "OVERLAY")
        sw.ring:SetPoint("TOPLEFT", sw, "TOPLEFT", -2, 2)
        sw.ring:SetPoint("BOTTOMRIGHT", sw, "BOTTOMRIGHT", 2, -2)
        sw.ring:SetTexture(1, 1, 1, 0.35)
        sw:SetScript("OnClick", function() bar.tag = (bar.tag == key) and "" or key; S:PaintSwatches() end)
        bar.swatches[key] = sw
    end
    bar.save = UI.Button(bar, "Save", 56, 20, function()
        S:SetNote(bar.name, bar.box:GetText(), bar.tag or "")
        S:RebuildTags()
        bar:Hide()
    end)
    bar.save:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -8, -24)
    local close = UI.CloseButton(bar, function() bar:Hide() end, 18)
    close:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 2, 0)
    bar:Hide()
    return bar
end

function S:PaintSwatches()
    local bar = ui.note
    for key, sw in pairs(bar.swatches) do if key == bar.tag then sw.ring:Show() else sw.ring:Hide() end end
end

function S:EditNote(name)
    self:Show()
    local bar = ui.note
    local p = self:Person(name) or {}
    bar.name = name
    bar.tag = p.tag or ""
    bar.title:SetText("NOTE FOR " .. strupper(name))
    bar.box:SetText(p.note or "")
    self:PaintSwatches()
    bar:Show()
end

-- Friends -------------------------------------------------------------------------------------

local SORTS = { { "status", "Online first" }, { "name", "Name" }, { "level", "Level" }, { "zone", "Zone" } }

local function buildFriends(p)
    local f = { sort = 1 }
    f.search = editBox(p, "Social_FriendSearch", 150, 40, "Search friends")
    f.search:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
    local base = f.search:GetScript("OnTextChanged")
    f.search:SetScript("OnTextChanged", function() if base then base() end S:Refresh() end)
    f.sortBtn = CreateFrame("Button", "Social_FriendSort", p)
    UI.Skin(f.sortBtn, "inset")
    f.sortBtn:SetWidth(110)
    f.sortBtn:SetHeight(18)
    f.sortBtn:SetPoint("LEFT", f.search, "RIGHT", 4, 0)
    f.sortBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f.sortBtn.text = UI.Label(f.sortBtn, 10, UI.ACCENT)
    f.sortBtn.text:SetPoint("CENTER", f.sortBtn, "CENTER", 0, 0)
    f.sortBtn.text:SetJustifyH("CENTER")
    f.sortBtn:SetScript("OnClick", function()
        f.sort = f.sort + ((arg1 == "RightButton") and -1 or 1)
        if f.sort > getn(SORTS) then f.sort = 1 elseif f.sort < 1 then f.sort = getn(SORTS) end
        S:Refresh()
    end)
    f.add = editBox(p, "Social_FriendAdd", 110, 12, "Name")
    f.add:SetPoint("TOPRIGHT", p, "TOPRIGHT", -62, 0)
    f.addBtn = UI.Button(p, "Add", 56, 18, function()
        local n = fixName(f.add:GetText())
        if n then AddFriend(n); f.add:SetText("") end
    end)
    f.addBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
    local box = inset(p, -24, 306 + EXTRA)
    f.list = UI.ScrollList(box, { width = PAGE_W - 4, height = 300 + EXTRA, rowHeight = 30,
        build = function(row, i)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            hl(row)
            row.dot = row:CreateTexture(nil, "ARTWORK")
            row.dot:SetWidth(8)
            row.dot:SetHeight(8)
            row.dot:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -7)
            row.name = UI.Label(row, 11, { 1, 1, 1 }, "OUTLINE")
            row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 20, -3)
            row.right = UI.Label(row, 10, { 0.8, 0.82, 0.88 })
            row.right:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -4)
            row.right:SetJustifyH("RIGHT")
            row.info = UI.Label(row, 10, UI.MUTED)
            row.info:SetPoint("TOPLEFT", row, "TOPLEFT", 20, -17)
            row.info:SetWidth(PAGE_W - 40)
            row:SetScript("OnClick", function()
                local x = row.item
                if x then personMenu(row, x.name, { friend = true, offline = not x.online, zone = x.online and x.zone or nil }) end
            end)
            setglobal("Social_Friend" .. i, row)
        end,
        update = function(row, x)
            local pres = x.online and S:PresenceOf(x.name) or ""
            if not x.online then row.dot:SetTexture(0.35, 0.36, 0.4, 1)
            else local c = PRESENCE_BY[pres].color; row.dot:SetTexture(c[1], c[2], c[3], 1) end
            local bits = { nameText(x.name, x.token, x.online) }
            if x.online and pres ~= "" then tinsert(bits, "|cff9da3b4" .. PRESENCE_BY[pres].label .. "|r") end
            local pp = Persona and Persona.Get and x.online and Persona.Get(x.name)
            local short = { ic = "|cff40ff40IC|r", ooc = "|cffff8040OOC|r", lfrp = "|cff40c0ffLFRP|r", st = "|cffd8a0ffStory|r" }
            if pp and pp.rev and pp.rev >= 0 and short[pp.status or ""] then tinsert(bits, short[pp.status]) end
            if S:Muted(x.name) then tinsert(bits, "|cff6a6d76(muted)|r") end
            row.name:SetText(table.concat(bits, "  "))
            if x.online then
                row.right:SetText(x.level .. " " .. (CLASS_NAME[x.token or ""] or x.class or ""))
                row.info:SetText(clean(x.zone) .. (noteLine(x.name) and ("  " .. DOT .. "  " .. noteLine(x.name)) or ""))
            else
                local seen = ago((S:Person(x.name) or {}).seen)
                row.right:SetText("")
                row.info:SetText("|cff7a7d86Offline" .. (seen and (" " .. DOT .. " last seen " .. seen) or "") .. "|r"
                    .. (noteLine(x.name) and ("  " .. DOT .. "  " .. noteLine(x.name)) or ""))
            end
        end,
    })
    f.list:SetPoint("TOPLEFT", box, "TOPLEFT", 2, -3)
    f.empty = UI.Label(box, 11, UI.MUTED)
    f.empty:SetPoint("CENTER", box, "CENTER", 0, -20)
    f.emptyArt = emptyArt(box, f.empty, "friends")
    f.footer = UI.Label(p, 10, UI.MUTED)
    f.footer:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -336 - EXTRA)
    return f
end

function S:FriendItems()
    local f = ui.friends
    local q = strlower(f.search:GetText() or "")
    local items = {}
    for _, x in ipairs(self.friends) do
        local p = self:Person(x.name) or {}
        local hay = strlower(x.name .. " " .. (x.zone or "") .. " " .. (p.note or "") .. " " .. (x.class or ""))
        if q == "" or strfind(hay, q, 1, true) then tinsert(items, x) end
    end
    local key = SORTS[f.sort][1]
    table.sort(items, function(a, b)
        if key == "status" or key == "zone" or key == "level" then
            if a.online ~= b.online then return a.online end
        end
        if key == "level" and a.level ~= b.level then return a.level > b.level end
        if key == "zone" and a.zone ~= b.zone then return a.zone < b.zone end
        return a.name < b.name
    end)
    return items
end

-- Guild ----------------------------------------------------------------------------------------

local function buildGuild(p)
    local g = { offline = true }
    g.head = UI.Label(p, 12, UI.ACCENT, "OUTLINE")
    g.head:SetPoint("TOPLEFT", p, "TOPLEFT", 2, 0)
    g.count = UI.Label(p, 10, UI.MUTED)
    g.count:SetPoint("TOPRIGHT", p, "TOPRIGHT", -2, -2)
    g.count:SetJustifyH("RIGHT")
    g.motd = UI.Label(p, 10, { 0.55, 0.95, 0.55 })
    g.motd:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -16)
    g.motd:SetWidth(PAGE_W - 4)
    g.search = editBox(p, "Social_GuildSearch", 120, 40, "Search the roster")
    g.search:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -40)
    local base = g.search:GetScript("OnTextChanged")
    g.search:SetScript("OnTextChanged", function() if base then base() end S:Refresh() end)
    g.offBtn = UI.Button(p, "Hide offline", 90, 18, function() g.offline = not g.offline; S:Refresh() end)
    g.offBtn:SetPoint("LEFT", g.search, "RIGHT", 4, 0)
    g.inviteName = editBox(p, "Social_GuildInviteName", 90, 12, "Name")
    g.inviteName:SetPoint("TOPRIGHT", p, "TOPRIGHT", -152, -40)
    g.rankBtn = CreateFrame("Button", "Social_GuildRank", p)
    UI.Skin(g.rankBtn, "inset")
    g.rankBtn:SetWidth(86)
    g.rankBtn:SetHeight(18)
    g.rankBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -62, -40)
    g.rankBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    g.rankBtn.text = UI.Label(g.rankBtn, 10, UI.ACCENT)
    g.rankBtn.text:SetPoint("CENTER", g.rankBtn, "CENTER", 0, 0)
    g.rankBtn.text:SetJustifyH("CENTER")
    g.rankBtn:SetScript("OnClick", function()
        local n = GuildControlGetNumRanks and GuildControlGetNumRanks() or 1
        local _, _, mine = GetGuildInfo("player")
        local lo = (mine or 0) + 1
        g.rank = (g.rank or (n - 1)) + ((arg1 == "RightButton") and -1 or 1)
        if g.rank > n - 1 then g.rank = lo elseif g.rank < lo then g.rank = n - 1 end
        S:Refresh()
    end)
    g.rankBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Rank for the newcomer", 1, 1, 1)
        GameTooltip:AddLine("They join at the lowest rank; Social promotes them to this one when they're in.", 0.8, 0.8, 0.8, 1)
        GameTooltip:Show()
    end)
    g.rankBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    g.inviteBtn = UI.Button(p, "Invite", 56, 18, function()
        if S:GuildInvite(g.inviteName:GetText(), g.rank) then g.inviteName:SetText("") end
    end)
    g.inviteBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, -40)
    local box = inset(p, -62, 270 + EXTRA)
    g.box = box
    g.list = UI.ScrollList(box, { width = PAGE_W - 4, height = 264 + EXTRA, rowHeight = 26,
        build = function(row, i)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            hl(row)
            row.name = UI.Label(row, 11, { 1, 1, 1 }, "OUTLINE")
            row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -2)
            row.rank = UI.Label(row, 10, UI.ACCENT)
            row.rank:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -3)
            row.rank:SetJustifyH("RIGHT")
            row.info = UI.Label(row, 10, UI.MUTED)
            row.info:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -14)
            row.info:SetWidth(PAGE_W - 30)
            row:SetScript("OnClick", function()
                local m = row.item
                if m and m.name ~= me() then personMenu(row, m.name, { offline = not m.online, zone = m.online and m.zone or nil }) end
            end)
            setglobal("Social_Guild" .. i, row)
        end,
        update = function(row, m)
            row.name:SetText(nameText(m.name, m.token, m.online) .. "  |cffc8ccd6" .. m.level .. " " .. (CLASS_NAME[m.token or ""] or m.class or "") .. "|r")
            row.rank:SetText(m.rank)
            local bits = {}
            if m.online then tinsert(bits, clean(m.zone)) else tinsert(bits, "|cff7a7d86Offline" .. (m.last and (" " .. DOT .. " last seen " .. m.last) or "") .. "|r") end
            if not blank(m.note) then tinsert(bits, "\"" .. clean(m.note) .. "\"") end
            if not blank(m.prof) then tinsert(bits, clean(m.prof)) end
            if noteLine(m.name) then tinsert(bits, noteLine(m.name)) end
            row.info:SetText(table.concat(bits, "  " .. DOT .. "  "))
        end,
    })
    g.list:SetPoint("TOPLEFT", box, "TOPLEFT", 2, -3)
    g.none = UI.Label(p, 11, UI.MUTED)
    g.none:SetPoint("TOP", p, "TOP", 0, -120)
    g.none:SetWidth(PAGE_W - 60)
    g.none:SetJustifyH("CENTER")
    g.none:SetText("You're not in a guild.\nThe Guilds board lists the guilds that are recruiting.")
    g.find = UI.Button(p, "Find a guild", 110, 22, function()
        local fn = SlashCmdList and SlashCmdList["GUILDS"]
        if fn then fn("") end
    end)
    g.find:SetPoint("TOP", g.none, "BOTTOM", 0, -12)
    return g
end

function S:GuildItems()
    local g = ui.guild
    local q = strlower(g.search:GetText() or "")
    local items = {}
    for _, m in ipairs(self.roster) do
        local hay = strlower(m.name .. " " .. m.zone .. " " .. m.rank .. " " .. m.note .. " " .. (m.class or ""))
        if (g.offline or m.online) and (q == "" or strfind(hay, q, 1, true)) then tinsert(items, m) end
    end
    table.sort(items, function(a, b)
        if a.online ~= b.online then return a.online end
        if a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
        return a.name < b.name
    end)
    return items
end

-- Group ---------------------------------------------------------------------------------------------

S.roles = {}   -- name -> "t" | "h" | "d", set from this tab

local function roleOf(name)
    if S.roles[name] then return S.roles[name] end
    if Dungeons and Dungeons.listings then
        local l = Dungeons.listings[name]
        if l and l.roles then for _, k in ipairs({ "t", "h", "d" }) do if l.roles[k] then return k end end end
        if name == me() and Dungeons.DB then
            local r = Dungeons.DB().prefs.roles
            if r then for _, k in ipairs({ "t", "h", "d" }) do if r[k] then return k end end end
        end
    end
    return nil
end
S.RoleOf = roleOf

local ROLE_ICON = {
    t = { "Dungeons_Tank", "Interface\\Icons\\Ability_Warrior_DefensiveStance" },
    h = { "Dungeons_Healer", "Interface\\Icons\\Spell_Holy_FlashHeal" },
    d = { "Dungeons_Damage", "Interface\\Icons\\INV_Sword_04" },
}
local ROLE_WORD = { t = "Tank", h = "Healer", d = "Damage" }

function S:GroupMembers()
    local out = {}
    local r = GetNumRaidMembers and GetNumRaidMembers() or 0
    if r > 0 then
        for i = 1, r do
            local n, rank, sub, lvl, class, token, zone, online = GetRaidRosterInfo(i)
            if n then tinsert(out, { name = n, leader = rank == 2, level = lvl, token = token or tokenOf(class), zone = zone, sub = sub, online = online }) end
        end
        return out, "raid"
    end
    local n = GetNumPartyMembers and GetNumPartyMembers() or 0
    if n == 0 then return out, nil end
    local _, myClass = UnitClass("player")
    tinsert(out, { name = me(), level = UnitLevel("player"), token = myClass, leader = IsPartyLeader and IsPartyLeader() and true, online = true })
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then
            local _, token = UnitClass(u)
            tinsert(out, { name = UnitName(u), level = UnitLevel(u), token = token, leader = UnitIsPartyLeader and UnitIsPartyLeader(u) and true,
                online = UnitIsConnected and UnitIsConnected(u) and true })
        end
    end
    return out, "party"
end

local function lootLabel(m)
    for _, l in ipairs(LOOT) do if l[1] == m then return l[2] end end
    return m or "Group loot"
end

function S:ReadyCheck()
    if Rally and Rally.StartCheck and W:IsActive("Raid") then return Rally:StartCheck() end
    if (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0 and DoReadyCheck then return DoReadyCheck() end
    W.Print("Social: join a group to run a ready check.")
end

function S:CycleLoot()
    if not GetLootMethod or not SetLootMethod then return end
    local cur = GetLootMethod()
    local i = 1
    for j, l in ipairs(LOOT) do if l[1] == cur then i = j end end
    i = i + 1
    if i > getn(LOOT) then i = 1 end
    if LOOT[i][1] == "master" then SetLootMethod("master", me()) else SetLootMethod(LOOT[i][1]) end
end

local function buildGroup(p)
    local gp = {}
    gp.head = UI.Label(p, 11, UI.ACCENT, "OUTLINE")
    gp.head:SetPoint("TOPLEFT", p, "TOPLEFT", 2, 0)
    gp.ready = UI.Button(p, "Ready check", 90, 18, function() S:ReadyCheck() end)
    gp.ready:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
    gp.loot = UI.Button(p, "Loot: Group loot", 150, 18, function() S:CycleLoot() end)
    gp.loot:SetPoint("RIGHT", gp.ready, "LEFT", -4, 0)
    local box = inset(p, -22, 124)
    gp.list = UI.ScrollList(box, { width = PAGE_W - 4, height = 120, rowHeight = 20,
        build = function(row, i)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            hl(row)
            row.role = CreateFrame("Button", nil, row)
            row.role:SetWidth(16)
            row.role:SetHeight(16)
            row.role:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.role.tex = row.role:CreateTexture(nil, "ARTWORK")
            row.role.tex:SetAllPoints(row.role)
            row.role:SetScript("OnClick", function()
                local m = row.item
                if not m then return end
                local order = { t = "h", h = "d", d = "t" }
                S.roles[m.name] = order[roleOf(m.name) or "d"]
                S:Refresh()
            end)
            row.name = UI.Label(row, 11, { 1, 1, 1 }, "OUTLINE")
            row.name:SetPoint("LEFT", row, "LEFT", 26, 0)
            row.info = UI.Label(row, 10, UI.MUTED)
            row.info:SetPoint("RIGHT", row, "RIGHT", -8, 0)
            row.info:SetJustifyH("RIGHT")
            row:SetScript("OnClick", function()
                local m = row.item
                if m and m.name ~= me() then personMenu(row, m.name, { zone = m.zone }) end
            end)
            setglobal("Social_Member" .. i, row)
        end,
        update = function(row, m)
            local r = roleOf(m.name)
            if r then
                if not W:Art(row.role.tex, ROLE_ICON[r][1], ROLE_ICON[r][2]) then row.role.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                else row.role.tex:SetTexCoord(0, 1, 0, 1) end
                row.role.tex:SetAlpha(1)
            else
                row.role.tex:SetTexture(0.25, 0.26, 0.3, 1)
                row.role.tex:SetAlpha(0.6)
            end
            row.name:SetText(nameText(m.name, m.token, m.online ~= false) .. (m.leader and "  |cffffd100(leader)|r" or "")
                .. (r and ("  |cff9da3b4" .. ROLE_WORD[r] .. "|r") or ""))
            row.info:SetText((m.level or "?") .. " " .. (CLASS_NAME[m.token or ""] or "") .. (m.sub and ("  " .. DOT .. "  group " .. m.sub) or ""))
        end,
    })
    gp.list:SetPoint("TOPLEFT", box, "TOPLEFT", 2, -2)
    gp.alone = UI.Label(box, 11, UI.MUTED)
    gp.alone:SetPoint("CENTER", box, "CENTER", 0, 0)
    gp.alone:SetText("You're not in a group. Find one on the board below.")
    gp.cap = UI.Label(p, 10, UI.MUTED, "OUTLINE")
    gp.cap:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -154)
    gp.cap:SetText("DUNGEONS BOARD")
    if Dungeons and Dungeons.CreateBrowser then
        gp.board = Dungeons:CreateBrowser(p, { width = PAGE_W, height = PAGE_H - 170, name = "Social_Board" })
        gp.board.frame:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -168)
        gp.open = UI.Button(p, "Open Dungeons", 100, 16, function() Dungeons:Show("mine") end)
        gp.open:SetPoint("TOPLEFT", p, "TOPLEFT", 120, -151)
    else
        gp.noBoard = UI.Label(p, 11, UI.MUTED)
        gp.noBoard:SetPoint("TOP", p, "TOP", 0, -200)
        gp.noBoard:SetText("Turn on Dungeons in /addons to find groups here.")
    end
    return gp
end

-- Who ----------------------------------------------------------------------------------------------

local function buildWho(p)
    local w = {}
    w.name = editBox(p, "Social_WhoName", 110, 12, "Name")
    w.name:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
    w.lo = editBox(p, "Social_WhoMin", 34, 2, "Lvl")
    w.lo:SetPoint("LEFT", w.name, "RIGHT", 4, 0)
    w.lo:SetNumeric(true)
    local dash = UI.Label(p, 10, UI.MUTED)
    dash:SetPoint("LEFT", w.lo, "RIGHT", 2, 0)
    dash:SetText("-")
    w.hi = editBox(p, "Social_WhoMax", 34, 2, "")
    w.hi:SetPoint("LEFT", w.lo, "RIGHT", 10, 0)
    w.hi:SetNumeric(true)
    w.classBtn = CreateFrame("Button", "Social_WhoClass", p)
    UI.Skin(w.classBtn, "inset")
    w.classBtn:SetWidth(80)
    w.classBtn:SetHeight(18)
    w.classBtn:SetPoint("LEFT", w.hi, "RIGHT", 4, 0)
    w.classBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    w.classBtn.text = UI.Label(w.classBtn, 10, UI.ACCENT)
    w.classBtn.text:SetPoint("CENTER", w.classBtn, "CENTER", 0, 0)
    w.classBtn.text:SetJustifyH("CENTER")
    w.classBtn:SetScript("OnClick", function()
        local n = getn(CLASS_ORDER)
        S.who.class = S.who.class + ((arg1 == "RightButton") and -1 or 1)
        if S.who.class > n then S.who.class = 0 elseif S.who.class < 0 then S.who.class = n end
        S:Refresh()
    end)
    w.zone = editBox(p, "Social_WhoZone", 110, 40, "Zone")
    w.zone:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -22)
    w.guild = editBox(p, "Social_WhoGuild", 110, 40, "Guild")
    w.guild:SetPoint("LEFT", w.zone, "RIGHT", 4, 0)
    w.go = UI.Button(p, "Search", 80, 18, function() S:SearchWho() end)
    w.go:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, -22)
    for _, box in ipairs({ w.name, w.lo, w.hi, w.zone, w.guild }) do
        box:SetScript("OnEnterPressed", function() this:ClearFocus(); S:SearchWho() end)
    end
    w.status = UI.Label(p, 10, UI.MUTED)
    w.status:SetPoint("RIGHT", w.go, "LEFT", -6, 0)
    w.status:SetJustifyH("RIGHT")
    -- sortable column heads
    local x = 4
    w.heads = {}
    for _, c in ipairs({ { "name", "Name", 110 }, { "level", "Level", 46 }, { "class", "Class", 70 }, { "zone", "Zone", 120 } }) do
        local key = c[1]
        local h = CreateFrame("Button", nil, p)
        h:SetWidth(c[3])
        h:SetHeight(16)
        h:SetPoint("TOPLEFT", p, "TOPLEFT", x, -46)
        h.text = UI.Label(h, 10, UI.MUTED, "OUTLINE")
        h.text:SetPoint("LEFT", h, "LEFT", 0, 0)
        h.text:SetText(strupper(c[2]))
        h:SetScript("OnClick", function() S:SortWho(key) end)
        w.heads[key] = h
        x = x + c[3]
    end
    local box = inset(p, -64, 286 + EXTRA)
    w.list = UI.ScrollList(box, { width = PAGE_W - 4, height = 280 + EXTRA, rowHeight = 20,
        build = function(row, i)
            hl(row)
            row.name = UI.Label(row, 10, { 1, 1, 1 }, "OUTLINE")
            row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.level = UI.Label(row, 10, { 0.9, 0.9, 0.95 })
            row.level:SetPoint("LEFT", row, "LEFT", 114, 0)
            row.class = UI.Label(row, 10, { 0.9, 0.9, 0.95 })
            row.class:SetPoint("LEFT", row, "LEFT", 160, 0)
            row.zone = UI.Label(row, 10, UI.MUTED)
            row.zone:SetPoint("LEFT", row, "LEFT", 230, 0)
            row.zone:SetWidth(120)
            row.inv = UI.Button(row, "Invite", 48, 16, function() if row.item then S:Invite(row.item.name) end end)
            row.inv:SetPoint("RIGHT", row, "RIGHT", -2, 0)
            row.wsp = UI.Button(row, "Whisper", 54, 16, function() if row.item then S:Whisper(row.item.name) end end)
            row.wsp:SetPoint("RIGHT", row.inv, "LEFT", -2, 0)
            row:SetScript("OnEnter", function()
                local x = row.item
                if not x then return end
                GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                GameTooltip:SetText("|c" .. classHex(x.token) .. x.name .. "|r")
                GameTooltip:AddLine("Level " .. x.level .. " " .. x.race .. " " .. x.class, 0.9, 0.9, 0.95)
                if x.guild ~= "" then GameTooltip:AddLine("<" .. x.guild .. ">", 0.4, 1, 0.4) end
                GameTooltip:AddLine(x.zone, 0.7, 0.7, 0.75)
                local nl = noteLine(x.name)
                if nl then GameTooltip:AddLine(nl) end
                if S.IsLive and S:IsLive(x.name) then GameTooltip:AddLine(S.LIVE_TAG .. "|cffffd8d0  streaming now|r") end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            setglobal("Social_Who" .. i, row)
        end,
        update = function(row, x)
            row.name:SetText("|c" .. classHex(x.token) .. x.name .. "|r" .. (S.LiveTag and S:LiveTag(x.name, true) or ""))
            row.level:SetText(x.level)
            row.class:SetText(x.class)
            row.zone:SetText(clean(x.zone) .. (x.guild ~= "" and ("  |cff60c060<" .. clean(x.guild) .. ">|r") or ""))
        end,
    })
    w.list:SetPoint("TOPLEFT", box, "TOPLEFT", 2, -3)
    w.empty = UI.Label(box, 11, UI.MUTED)
    w.emptyArt = emptyArt(box, w.empty, "who")
    w.empty:SetPoint("CENTER", box, "CENTER", 0, -20)
    w.empty:SetWidth(PAGE_W - 60)
    w.empty:SetJustifyH("CENTER")
    return w
end

-- Ignore ---------------------------------------------------------------------------------------------

local function buildIgnore(p)
    local ig = {}
    ig.name = editBox(p, "Social_IgnoreName", 110, 12, "Name")
    ig.name:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
    ig.note = editBox(p, "Social_IgnoreNote", 250, 80, "Why (only you see this)")
    ig.note:SetPoint("LEFT", ig.name, "RIGHT", 4, 0)
    ig.add = UI.Button(p, "Ignore", 80, 18, function()
        if Ignore.Add(ig.name:GetText(), ig.note:GetText()) then ig.name:SetText(""); ig.note:SetText("") end
    end)
    ig.add:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
    local hint = UI.Label(p, 10, UI.MUTED)
    hint:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -24)
    hint:SetWidth(PAGE_W - 4)
    hint:SetText("One list for chat, whispers, Persona, Dungeons and every other Classic+ window.")
    local box = inset(p, -40, 300 + EXTRA)
    ig.list = UI.ScrollList(box, { width = PAGE_W - 4, height = 294 + EXTRA, rowHeight = 26,
        build = function(row, i)
            hl(row)
            row.name = UI.Label(row, 11, { 1, 0.6, 0.55 }, "OUTLINE")
            row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -2)
            row.info = UI.Label(row, 10, UI.MUTED)
            row.info:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -14)
            row.info:SetWidth(PAGE_W - 100)
            row.remove = UI.Button(row, "Remove", 64, 18, function() if row.item then Ignore.Remove(row.item.name) end end)
            row.remove:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            setglobal("Social_Ignore" .. i, row)
        end,
        update = function(row, e)
            row.name:SetText(e.name)
            local bits = {}
            if not blank(e.note) then tinsert(bits, "\"" .. clean(e.note) .. "\"") end
            local when = ago(e.at)
            if when then tinsert(bits, "since " .. when) end
            if not bits[1] then tinsert(bits, "no note") end
            row.info:SetText(table.concat(bits, "  " .. DOT .. "  "))
        end,
    })
    ig.list:SetPoint("TOPLEFT", box, "TOPLEFT", 2, -3)
    ig.empty = UI.Label(box, 11, UI.MUTED)
    ig.emptyArt = emptyArt(box, ig.empty, "ignore")
    ig.empty:SetPoint("CENTER", box, "CENTER", 0, -20)
    ig.empty:SetText("Nobody on your ignore list.")
    return ig
end

-- Recent ---------------------------------------------------------------------------------------------

local function buildRecent(p)
    local rc = {}
    local hint = UI.Label(p, 10, UI.MUTED)
    hint:SetPoint("TOPLEFT", p, "TOPLEFT", 2, 0)
    hint:SetText("People you grouped, traded or duelled with lately.")
    local box = inset(p, -18, 322 + EXTRA)
    rc.list = UI.ScrollList(box, { width = PAGE_W - 4, height = 316 + EXTRA, rowHeight = 28,
        build = function(row, i)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            hl(row)
            row.name = UI.Label(row, 11, { 1, 1, 1 }, "OUTLINE")
            row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -2)
            row.info = UI.Label(row, 10, UI.MUTED)
            row.info:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -15)
            row.add = UI.Button(row, "Add friend", 74, 18, function() if row.item then AddFriend(row.item.name) end end)
            row.add:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.inv = UI.Button(row, "Invite", 50, 18, function() if row.item then S:Invite(row.item.name) end end)
            row.inv:SetPoint("RIGHT", row.add, "LEFT", -2, 0)
            row.wsp = UI.Button(row, "Whisper", 58, 18, function() if row.item then S:Whisper(row.item.name) end end)
            row.wsp:SetPoint("RIGHT", row.inv, "LEFT", -2, 0)
            row:SetScript("OnClick", function() if row.item then personMenu(row, row.item.name, {}) end end)
            setglobal("Social_Recent" .. i, row)
        end,
        update = function(row, r)
            row.name:SetText(nameText(r.name, r.class, true) .. (r.level and ("  |cffc8ccd6" .. r.level .. " " .. (CLASS_NAME[r.class or ""] or "") .. "|r") or ""))
            row.info:SetText(r.what .. (not blank(r.zone) and (" in " .. clean(r.zone)) or "") .. "  " .. DOT .. "  " .. (ago(r.at) or ""))
            if S:IsFriend(r.name) then row.add:Hide() else row.add:Show() end
        end,
    })
    rc.list:SetPoint("TOPLEFT", box, "TOPLEFT", 2, -3)
    rc.empty = UI.Label(box, 11, UI.MUTED)
    rc.emptyArt = emptyArt(box, rc.empty, "recent")
    rc.empty:SetPoint("CENTER", box, "CENTER", 0, -20)
    rc.empty:SetText("Nobody yet. Group up, trade or duel and they show up here.")
    return rc
end

-- the window itself ------------------------------------------------------------------------------------

local sheet
local function build()
    if win then return win end
    win = UI.ClassicFrame("Social_Frame", { width = WIN_W, height = WIN_H, title = "Social",
        portrait = PORTRAIT, point = { "LEFT", UIParent, "LEFT", 40, 40 },
        tabs = TABS, onTab = function(key) S:ShowTab(key) end })
    win:SetFrameStrata("HIGH")
    tinsert(UISpecialFrames, "Social_Frame")
    win:Hide()

    local gear = UI.GearButton(win, function() sheet:Toggle() end, 14)
    gear:SetPoint("RIGHT", win.titleBar, "RIGHT", -4, 0)

    ui.presence = CreateFrame("Button", "Social_Presence", win)
    UI.Skin(ui.presence, "inset")
    ui.presence:SetWidth(130)
    ui.presence:SetHeight(18)
    ui.presence:SetPoint("RIGHT", win.toolbar, "RIGHT", -2, 0)
    ui.presence:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    ui.presence.dot = ui.presence:CreateTexture(nil, "ARTWORK")
    ui.presence.dot:SetWidth(8)
    ui.presence.dot:SetHeight(8)
    ui.presence.dot:SetPoint("LEFT", ui.presence, "LEFT", 6, 0)
    ui.presence.text = UI.Label(ui.presence, 10, { 1, 1, 1 })
    ui.presence.text:SetPoint("LEFT", ui.presence.dot, "RIGHT", 5, 0)
    ui.presence:SetScript("OnClick", function() S:CyclePresence(arg1 == "RightButton") end)
    ui.presence:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetText("Your presence", 1, 1, 1)
        GameTooltip:AddLine("Friends and the Dungeons board see it. Click to change.", 0.8, 0.8, 0.8, 1)
        GameTooltip:Show()
    end)
    ui.presence:SetScript("OnLeave", function() GameTooltip:Hide() end)

    S.tabs = win.tabs
    -- the header band: what this tab is, left of the presence button
    ui.heading = win.toolbar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.heading:SetPoint("LEFT", win.toolbar, "LEFT", 4, 0)

    for _, t in ipairs(TABS) do
        local p = CreateFrame("Frame", nil, win.body)
        p:SetPoint("TOPLEFT", win.body, "TOPLEFT", 0, 0)
        p:SetWidth(PAGE_W)
        p:SetHeight(PAGE_H)
        p:Hide()
        pages[t.key] = p
    end
    ui.friends = buildFriends(pages.friends)
    ui.guild = buildGuild(pages.guild)
    ui.group = buildGroup(pages.group)
    ui.who = buildWho(pages.who)
    S.whoUI = ui.who
    ui.ignore = buildIgnore(pages.ignore)
    ui.recent = buildRecent(pages.recent)
    ui.note = buildNoteBar()

    ui.stock = UI.Button(win, "Blizzard's window", 120, 16, function() S:OpenStock() end)
    ui.stock:SetPoint("BOTTOMRIGHT", win.body, "BOTTOMRIGHT", 0, 0)
    ui.stock:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_TOP")
        GameTooltip:SetText("The stock Friends window", 1, 1, 1)
        GameTooltip:AddLine("Switch off \"Open with O\" in the settings to make it the default again.", 0.8, 0.8, 0.8, 1)
        GameTooltip:Show()
    end)
    ui.stock:SetScript("OnLeave", function() GameTooltip:Hide() end)

    sheet = UI.Sheet(win, { title = "Social settings", width = 230 })
    for _, o in ipairs(S.SCHEMA.options) do
        local key, def = o.key, S.SCHEMA.defaults[o.key]
        sheet:AddSwitch(o.label, o.sub, function() return setting(key, def) end,
            function(v) W:Settings(ID)[key] = v; W:Refresh(ID) end)
    end
    if S.AddArmorySheet then S.AddArmorySheet(sheet) end   -- Armory.lua: public / friends only / hidden
    S.sheet = sheet

    -- number keys switch tabs while the mouse is over the window
    win:SetScript("OnKeyDown", function() S:HandleKey(arg1) end)
    local kbAcc, kb = 0, false
    win:SetScript("OnUpdate", function()
        kbAcc = kbAcc + (arg1 or 0)
        if kbAcc < 0.1 then return end
        kbAcc = 0
        local over = MouseIsOver and MouseIsOver(win) and true or false
        if over ~= kb then kb = over; if win.EnableKeyboard then win:EnableKeyboard(over) end end
    end)
    win:SetScript("OnShow", function()
        if ShowFriends then ShowFriends() end
        if IsInGuild and IsInGuild() and GuildRoster then GuildRoster() end
        if PlaySound then PlaySound("igCharacterInfoOpen") end
        S:Refresh()
    end)
    win:SetScript("OnHide", function()
        if sheet then sheet:Hide() end
        ui.note:Hide()
        if win.EnableKeyboard then win:EnableKeyboard(false) end
        kb = false
        if PlaySound then PlaySound("igCharacterInfoClose") end
    end)
    return win
end

function S:HandleKey(key)
    local n = tonumber(key)
    if n and TABS[n] then self:ShowTab(TABS[n].key) return true end
    if key == "ESCAPE" or key == "O" then if win then win:Hide() end return true end
    return false
end

function S:ShowTab(key)
    build()
    for k, p in pairs(pages) do if k == key then p:Show() else p:Hide() end end
    self.tab = key
    if self.tabs:Selected() ~= key then self.tabs:Select(key, true) end
    if key == "guild" and IsInGuild and IsInGuild() and GuildRoster then GuildRoster() end
    self:Refresh()
end

function S:Show(tab)
    if not W:IsActive(ID) then W.Print("Social is switched off. Turn it on in /addons.") return end
    build()
    win:Show()
    self:ShowTab(tab or self.tab or "friends")
end

function S:Toggle(tab)
    build()
    if win:IsShown() and (not tab or tab == self.tab) then win:Hide() else self:Show(tab) end
end

function S:Refresh()
    if not win or not win:IsShown() then return end
    local pr = PRESENCE_BY[self:MyPresence()] or PRESENCE[1]
    ui.presence.dot:SetTexture(pr.color[1], pr.color[2], pr.color[3], 1)
    ui.presence.text:SetText(pr.label)
    local t = self.tab
    if t == "friends" then
        local f = ui.friends
        local items = self:FriendItems()
        f.list:SetItems(items)
        f.sortBtn.text:SetText("Sort: " .. SORTS[f.sort][2])
        local on = 0
        for _, x in ipairs(self.friends) do if x.online then on = on + 1 end end
        f.footer:SetText(on .. " of " .. getn(self.friends) .. " friends online")
        if getn(items) == 0 then
            f.empty:SetText(getn(self.friends) == 0 and "No friends yet. Type a name above and press Add." or "No friends match your search.")
            f.empty:Show()
        else f.empty:Hide() end
    elseif t == "guild" then
        local g = ui.guild
        local inGuild = IsInGuild and IsInGuild()
        local all = { g.head, g.count, g.motd, g.search, g.offBtn, g.box }
        for _, x in ipairs(all) do if inGuild then x:Show() else x:Hide() end end
        if inGuild then
            g.none:Hide(); g.find:Hide()
            local name = GetGuildInfo("player")
            g.head:SetText("<" .. (name or "") .. ">")
            local on = 0
            for _, m in ipairs(self.roster) do if m.online then on = on + 1 end end
            g.count:SetText(on .. " of " .. getn(self.roster) .. " online")
            local motd = GetGuildRosterMOTD and GetGuildRosterMOTD() or ""
            g.motd:SetText(motd ~= "" and ("Message of the day: " .. clean(motd)) or "")
            g.offBtn:SetText(g.offline and "Hide offline" or "Show offline")
            g.list:SetItems(self:GuildItems())
            local can = CanGuildInvite and CanGuildInvite()
            for _, x in ipairs({ g.inviteName, g.inviteBtn, g.rankBtn }) do if can then x:Show() else x:Hide() end end
            if can then
                local n = GuildControlGetNumRanks and GuildControlGetNumRanks() or 1
                g.rank = g.rank or (n - 1)
                g.rankBtn.text:SetText(GuildControlGetRankName and GuildControlGetRankName(g.rank + 1) or "Member")
            end
        else
            g.none:Show()
            if SlashCmdList and SlashCmdList["GUILDS"] then g.find:Show() else g.find:Hide() end
            for _, x in ipairs({ g.inviteName, g.inviteBtn, g.rankBtn }) do x:Hide() end
        end
    elseif t == "group" then
        local gp = ui.group
        local members, kind = self:GroupMembers()
        gp.list:SetItems(members)
        if kind then
            gp.alone:Hide()
            gp.head:SetText((kind == "raid" and "Raid" or "Party") .. " of " .. getn(members))
            gp.loot:SetText("Loot: " .. lootLabel(GetLootMethod and GetLootMethod()))
            gp.loot:Show(); gp.ready:Show()
        else
            gp.alone:Show()
            gp.head:SetText("Not in a group")
            gp.loot:Hide(); gp.ready:Hide()
        end
        if gp.board and Dungeons then Dungeons:RefreshBrowser(gp.board) end
    elseif t == "who" then
        local w = ui.who
        w.classBtn.text:SetText(self.who.class > 0 and CLASS_NAME[CLASS_ORDER[self.who.class]] or "Any class")
        w.list:SetItems(self.who.results)
        local wait = self:WhoWait()
        if self.who.pending then w.status:SetText("Searching...")
        else w.status:SetText(getn(self.who.results) .. " found") end
        if wait > 0 then w.go:Disable(); w.go:SetText("Wait " .. math.ceil(wait) .. "s")
        else w.go:Enable(); w.go:SetText("Search") end
        for k, h in pairs(w.heads) do
            if k == self.who.sort then h.text:SetTextColor(1, 0.82, 0) else h.text:SetTextColor(UI.MUTED[1], UI.MUTED[2], UI.MUTED[3]) end
        end
        if getn(self.who.results) == 0 then
            w.empty:SetText(self.who.query and "Nobody matches that search." or "Search for players by name, level, class, zone or guild.")
            w.empty:Show()
        else w.empty:Hide() end
    elseif t == "ignore" then
        local items = Ignore.List()
        ui.ignore.list:SetItems(items)
        if getn(items) == 0 then ui.ignore.empty:Show() else ui.ignore.empty:Hide() end
    elseif t == "recent" then
        local items = {}
        for _, r in ipairs(char().recent) do if not Ignore.IsIgnored(r.name) then tinsert(items, r) end end
        ui.recent.list:SetItems(items)
        if getn(items) == 0 then ui.recent.empty:Show() else ui.recent.empty:Hide() end
    end
    -- the empty-state emblem follows its line; the header band names the tab
    for _, k in ipairs({ "friends", "who", "ignore", "recent" }) do
        local pg = ui[k]
        if pg and pg.emptyArt then
            local on = pg.empty:IsShown() and t == k
            for _, x in ipairs(pg.emptyArt) do if on then x:Show() else x:Hide() end end
        end
    end
    if ui.heading then
        for _, tb in ipairs(TABS) do if tb.key == t then ui.heading:SetText(tb.label) end end
    end
end

-- -- Taking over O ----------------------------------------------------------------------------------------------------

local stockToggle = ToggleFriendsFrame
S.bypass = false

-- The window opens only when the player asked: O, the Socials button, /social, a toast, or a /who
-- typed in chat (its results open the Who tab). Anything else that shows the stock Friends frame or
-- brings /who results (the stock UI opens it on any WHO_LIST_UPDATE) is ignored: it kept reopening
-- the window after it was closed.
S.askedAt, S.typedWhoAt = -100, -100
local function asked() return GetTime() - S.askedAt < 2 end
local function typedWho() return GetTime() - S.typedWhoAt < 15 end
S.Asked, S.TypedWho = asked, typedWho
if SlashCmdList and SlashCmdList["WHO"] then
    local stockWho = SlashCmdList["WHO"]
    SlashCmdList["WHO"] = function(msg) S.typedWhoAt = GetTime(); return stockWho(msg) end
end

function S:TakesOver() return W:IsActive(ID) and setting("replaceFriends", true) and true or false end

function S:OpenStock()
    if win then win:Hide() end
    self.bypass = true
    if stockToggle then stockToggle(1) elseif FriendsFrame then ShowUIPanel(FriendsFrame) end
    self.bypass = false
end

ToggleFriendsFrame = function(tab)
    S.askedAt = GetTime()
    if S:TakesOver() and not S.bypass then return S:Toggle(STOCK_TAB[tab or 1] or "friends") end
    if stockToggle then return stockToggle(tab) end
end

-- anything that shows the stock frame directly (the Who results, a stock button) lands here instead
if FriendsFrame then
    local origShow = FriendsFrame:GetScript("OnShow")
    FriendsFrame:SetScript("OnShow", function()
        if S:TakesOver() and not S.bypass then
            local tab = STOCK_TAB[FriendsFrame.selectedTab or 1] or "friends"
            if S.who.pending then tab = "who" end
            this:Hide()
            S.clearStock = true     -- next frame: free the UI panel slot the stock frame took
            if asked() or (tab == "who" and typedWho()) or S.who.pending then S:Show(tab) end
            return
        end
        if origShow then origShow() end
    end)
end

-- -- Events -------------------------------------------------------------------------------------------------------------

local ev = CreateFrame("Frame", "Social_Events")
for _, e in ipairs({ "VARIABLES_LOADED", "PLAYER_ENTERING_WORLD", "FRIENDLIST_UPDATE", "GUILD_ROSTER_UPDATE",
    "PLAYER_GUILD_UPDATE", "IGNORELIST_UPDATE", "WHO_LIST_UPDATE", "CHAT_MSG_SYSTEM", "CHAT_MSG_CHANNEL",
    "PARTY_MEMBERS_CHANGED", "RAID_ROSTER_UPDATE", "PARTY_LOOT_METHOD_CHANGED", "PARTY_LEADER_CHANGED",
    "TRADE_SHOW", "DUEL_REQUESTED", "PLAYER_LEVEL_UP", "UPDATE_MOUSEOVER_UNIT" }) do
    ev:RegisterEvent(e)
end

local joinAt, acc, pollAcc = nil, 0, 0
ev:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        db()
        S:RebuildTags()
    elseif event == "PLAYER_ENTERING_WORLD" then
        joinAt = GetTime() + JOIN_DELAY
        if ShowFriends then ShowFriends() end
        if IsInGuild and IsInGuild() then
            if SetGuildRosterShowOffline then SetGuildRosterShowOffline(1) end
            if GuildRoster then GuildRoster() end
        end
        S:ScanFriends()
    elseif event == "FRIENDLIST_UPDATE" then
        S:ScanFriends()
    elseif event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        S:ScanGuild()
    elseif event == "IGNORELIST_UPDATE" then
        Ignore.Sync()
        S:Refresh()
    elseif event == "WHO_LIST_UPDATE" then
        -- ours, or a /who typed in chat whose results the stock window would have shown
        local ours = S.who.pending
        S:ReadWho()
        if not ours then S.who.query = "/who" end
        if not ours and S:TakesOver() and typedWho() and not (win and win:IsShown() and S.tab == "who") then S:Show("who") end
    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = arg1 or ""
        local _, _, name = strfind(msg, "^|Hplayer:([^|]+)|h%[[^%]]*%]|h has come online")
        if not name then _, _, name = strfind(msg, "^%[?([^%]%s]+)%]? has come online") end
        if name then
            -- friends: the toast comes with the refreshed list (level and zone); guild mates
            -- right away, since the server throttles roster updates
            if guildSet[name] and not friendSet[name] then
                guildSet[name].online = true
                S:CameOnline(name)
            end
            if ShowFriends then ShowFriends() end
            if IsInGuild and IsInGuild() and GuildRoster then GuildRoster() end
        elseif strfind(msg, "has gone offline") then
            if ShowFriends then ShowFriends() end
        end
    elseif event == "CHAT_MSG_CHANNEL" then
        if strfind(strlower(arg9 or arg4 or ""), strlower(CHANNEL), 1, true) and W:IsActive(ID) then S:Receive(arg1, arg2) end
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        S:ScanGroup()
        S:Refresh()
    elseif event == "PARTY_LOOT_METHOD_CHANGED" or event == "PARTY_LEADER_CHANGED" then
        S:Refresh()
    elseif event == "TRADE_SHOW" then
        local n = UnitName("NPC")
        if n then local _, c = UnitClass("NPC"); S:Remember(n, "Traded", c, UnitLevel("NPC")) end
    elseif event == "DUEL_REQUESTED" then
        S:Remember(arg1, "Duelled")
    elseif event == "PLAYER_LEVEL_UP" then
        S:Announce()
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        decorateTooltip()
    end
end)

ev:SetScript("OnUpdate", function()
    flush(arg1)
    if S.clearStock then
        S.clearStock = nil
        if HideUIPanel and FriendsFrame then HideUIPanel(FriendsFrame) end
    end
    acc = acc + arg1
    if acc < 1 then return end
    pollAcc = pollAcc + acc
    acc = 0
    if not W:IsActive(ID) then return end
    local t = GetTime()
    if joinAt and t >= joinAt then
        joinAt = nil
        joinOpen = true
        join()
        S:Announce()
        send("?S")
    end
    if S.replyAt and t >= S.replyAt then S.replyAt = nil; S:Announce() end
    if t - lastAnnounce > 15 * 60 and channelId() then S:Announce() end
    if pollAcc >= 60 then
        pollAcc = 0
        if ShowFriends then ShowFriends() end
        if IsInGuild and IsInGuild() and GuildRoster then GuildRoster() end
    end
    if win and win:IsShown() and S.tab == "who" then S:Refresh() end
end)

-- -- Registration ---------------------------------------------------------------------------------------------------------

S.SCHEMA = {
    title = "Social - Friends, Guild & Group",
    icon = ICON,
    desc = "One window for friends, guild, group, /who, ignore and recent people. Opens with O instead of the stock Friends window. /social",
    defaults = { replaceFriends = true, toastFriends = true, toastGuild = true, toastLevel = true, toastSound = true,
        notesInTooltips = true, tagChatNames = true, showLive = false },
    options = {
        { key = "replaceFriends", label = "Open with O", sub = "O and the Socials button open this window. Off brings back the stock Friends window." },
        { key = "toastFriends", label = "Friend online toasts", sub = "A banner when a friend comes online." },
        { key = "toastGuild", label = "Guild online toasts", sub = "A banner when a guild mate comes online." },
        { key = "toastLevel", label = "Level up toasts", sub = "A banner when a friend or guild mate gains a level." },
        { key = "toastSound", label = "Toast sound", sub = "Play a sound with each banner." },
        { key = "notesInTooltips", label = "Notes in tooltips", sub = "Your private note under a player's name when you mouse over them." },
        { key = "tagChatNames", label = "Colour tags in chat", sub = "Names you tagged keep their colour in chat." },
        { key = "showLive", label = "Show me as LIVE", sub = "While you stream on a channel linked at openvanilla.app/creators.html (with this character named there), other players see LIVE next to your name. /live lists who is live." },
    },
}
W:RegisterSchema(ID, S.SCHEMA)

W:RegisterAddon(ID, function(active)
    if not active and win then win:Hide() end
end)

SLASH_SOCIAL1 = "/social"
SlashCmdList["SOCIAL"] = function(msg)
    S.askedAt = GetTime()
    msg = strlower(W.Trim(msg))
    if not W:IsActive(ID) then W.Print("Social is switched off. Turn it on in /addons.") return end
    for _, t in ipairs(TABS) do if msg == t.key then return S:Show(t.key) end end
    if msg == "away" or msg == "busy" or msg == "lfg" then return S:SetPresence(msg) end
    if msg == "back" or msg == "available" then return S:SetPresence("") end
    if msg == "help" then
        W.Print("/social [friends|guild|group|who|ignore|recent]   " .. DOT .. "   /social away | busy | lfg | back")
        return
    end
    S:Toggle()
end
