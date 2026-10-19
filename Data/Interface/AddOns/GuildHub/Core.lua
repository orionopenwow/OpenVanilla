--[[
    GuildHub/Core.lua  -  Guild Hub: the shared state and its wire.

    Guild Hub is one window for running a guild on a 1.12 realm (see Window.lua for the tabs):
    roster tools, recruitment (the Guilds board's post form plus the applications it brings in),
    events with sign-ups, a bank log for the guild's banker alt, DKP with an optional loot
    council, and the MOTD. It builds on Guilds (the recruitment board and its "[Guilds]" apply
    whisper) and Social (the roster tab, the shared ignore list WenillaCore.Ignore, invites with a
    rank preset) instead of repeating them.

    Everything guild-wide (events, sign-ups, DKP, bank log, requests, applications, alt links,
    council votes, each member's professions and achievement points) is a record kept in
    GuildHub_DB and synced between members over a hidden chat channel, CPGuild, that every
    member's client joins a few seconds after entering the world. The channel never shows in a
    chat window. Lines look like Persona's wire, chunked so a long payload spans several lines:

        GH1~<guild key>~<message id>~<i>/<n>~<payload chunk>

    <guild key> is a short hash of the guild name (the channel is realm-wide; other guilds' lines
    are ignored), and only lines from players on our own roster count. A payload is records
    separated by ';', each "kind,id,by,u,field,...". Fields are escaped (esc below) so a payload
    has no spaces, '~', '|', ',' or ';'. u is the record's last change (time()); the newer copy
    wins. Kinds (Data.lua writes them, KINDS below lists the fields):

        ev  event          su  sign-up          ap  application       dk  DKP entry
        bk  bank entry     rq  bank request     al  alt link          cf  guild settings
        lc  council vote   vo  council ballot   mi  member info (professions, points)
        Q   "send me <kind> newer than <u>"     R   "I am answering <who>'s Q"

    Who may write what is checked on arrival (Allowed): officer kinds need an officer author
    (rank index <= the guild's officer rank, Guild settings), a sign-up or member info must be
    the player's own, and only officers relay records that someone else wrote. Officers answer a
    login's Q after a random pause; the first answer silences the rest.

    Lua 5.0 rules (1.12.1 client): no '#', no '%' operator, no select / string.match; handlers
    read this/event/arg1..arg9.
]]--

local W = WenillaCore
local ID = "GuildHub"
local CHANNEL = "CPGuild"
local CHUNK = 200            -- payload bytes per line (a line maxes out at 255)
local SEND_GAP = 0.7         -- seconds between our own channel lines
local JOIN_DELAY = 6         -- after entering the world, so the stock channels keep their numbers
local INBOX_TTL = 60
local SKEW = 600             -- clock slack (seconds) when asking for "newer than"

GuildHub = GuildHub or {}
local G = GuildHub
G.ID = ID
G.CHANNEL = CHANNEL
G.version = "1.0.0"

local strfind, strsub, strgsub, strlen, strlower, strupper = string.find, string.sub, string.gsub, string.len, string.lower, string.upper
local tinsert, tremove, getn = table.insert, table.remove, table.getn
local floor = math.floor

G.DOT = "\194\183"

-- -- Small helpers ----------------------------------------------------------------------------

local function me() return UnitName("player") or "?" end
local function now() return time and time() or 0 end
local function blank(s) return not s or s == "" end
G.Me, G.Now, G.Blank = me, now, blank

function G.Mod(a, b) return a - floor(a / b) * b end
local mod = G.Mod

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
function G.B36(n)
    n = floor(tonumber(n) or 0)
    if n <= 0 then return "0" end
    local s = ""
    while n > 0 do
        local d = mod(n, 36)
        s = strsub(B36, d + 1, d + 1) .. s
        n = floor(n / 36)
    end
    return s
end

-- a short, stable key for a guild name (the channel is shared by every guild on the realm)
function G.GuildKey(name)
    local h = 7
    name = strlower(name or "")
    for i = 1, strlen(name) do h = mod(h * 31 + string.byte(name, i), 2147483629) end
    return G.B36(h)
end

-- shown literally in our frames: never let a name or note carry colour codes or links
function G.Plain(s)
    local r = strgsub(s or "", "|", "||")
    return r
end

-- Field escaping for the wire: no spaces (the server collapses them), no '~' (our separator),
-- no '|' (the client refuses raw pipes), no ',' / ';' (record separators).
local ESC = { ["\\"] = "\\e", ["~"] = "\\t", ["|"] = "\\p", [","] = "\\c", [";"] = "\\s", ["+"] = "\\a", ["\n"] = "\\n" }
local UNESC = { e = "\\", t = "~", p = "|", c = ",", s = ";", a = "+", n = "\n" }
function G.Esc(s)
    s = tostring(s or "")
    s = strgsub(s, "[\\~|,;%+\n]", function(c) return ESC[c] end)
    s = strgsub(s, " ", "+")
    return s
end
function G.Unesc(s)
    s = strgsub(s or "", "%+", " ")
    s = strgsub(s, "\\(.)", function(c) return UNESC[c] or c end)
    return s
end

-- copper -> "12g 50s" (no colour codes: also used in chat and exports)
function G.Money(c)
    c = floor(tonumber(c) or 0)
    local neg = c < 0
    if neg then c = -c end
    local g, s, k = floor(c / 10000), floor(mod(c, 10000) / 100), mod(c, 100)
    local out = {}
    if g > 0 then tinsert(out, g .. "g") end
    if s > 0 then tinsert(out, s .. "s") end
    if k > 0 or not out[1] then tinsert(out, k .. "c") end
    return (neg and "-" or "") .. table.concat(out, " ")
end

-- "12g 50s 3c", "12g", "75s", "12" (gold) -> copper, or nil
function G.ParseMoney(s)
    s = strlower(W.Trim(s or ""))
    if s == "" then return nil end
    local n = tonumber(s)
    if n then return floor(n * 10000 + 0.5) end
    local total, any = 0, false
    for _, u in ipairs({ { "g", 10000 }, { "s", 100 }, { "c", 1 } }) do
        local _, _, v = strfind(s, "(%d+)%s*" .. u[1])
        if v then total = total + tonumber(v) * u[2]; any = true end
    end
    if any then return total end
    return nil
end

function G.Ago(t)
    if not t or t == 0 then return nil end
    local d = now() - t
    if d < 120 then return "just now" end
    if d < 3600 then return floor(d / 60) .. " min ago" end
    if d < 86400 then local h = floor(d / 3600) return h .. " hour" .. (h == 1 and "" or "s") .. " ago" end
    local n = floor(d / 86400)
    return n .. " day" .. (n == 1 and "" or "s") .. " ago"
end

local CLASS_NAME = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
    SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}
G.CLASS_NAME = CLASS_NAME
local CLASS_TOKEN = {}
for k, v in pairs(CLASS_NAME) do CLASS_TOKEN[strlower(v)] = k end
function G.Token(class)
    if not class then return nil end
    return CLASS_TOKEN[strlower(class)] or (CLASS_NAME[strupper(class)] and strupper(class)) or nil
end
function G.ClassHex(token)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token or ""]
    local r, g, b
    if c then r, g, b = c.r, c.g, c.b else r, g, b = W.UI.ClassColor(token) end
    return string.format("ff%02x%02x%02x", floor(r * 255), floor(g * 255), floor(b * 255))
end
function G.ColorName(name, token)
    return "|c" .. G.ClassHex(token) .. G.Plain(name) .. "|r"
end

-- -- Saved data -------------------------------------------------------------------------------
-- GuildHub_DB.guilds["<realm>/<guild>"] = { ev = {}, su = {}, ap = {}, dk = {}, bk = {}, rq = {},
--     al = {}, cf = {}, lc = {}, vo = {}, mi = {}, reminded = {}, seq = n }
-- GuildHub_DB.chars["<realm>/<name>"] = { templates = {}, tab = "roster" }

local KIND_LIST = { "ev", "su", "ap", "dk", "bk", "rq", "al", "cf", "lc", "vo", "mi" }
G.KIND_LIST = KIND_LIST

function G.GuildName()
    if not (IsInGuild and IsInGuild()) then return nil end
    local name = GetGuildInfo and GetGuildInfo("player")
    if blank(name) then return nil end
    return name
end

function G.DB()
    if type(GuildHub_DB) ~= "table" then GuildHub_DB = {} end
    local d = GuildHub_DB
    d.guilds = d.guilds or {}
    d.chars = d.chars or {}
    return d
end

local emptyGuild = nil
function G.GDB()
    local name = G.GuildName()
    if not name then
        -- not in a guild: a scratch table nobody saves
        if not emptyGuild then
            emptyGuild = { reminded = {}, seq = 0 }
            for _, k in ipairs(KIND_LIST) do emptyGuild[k] = {} end
        end
        return emptyGuild
    end
    local d = G.DB()
    local key = (GetRealmName and GetRealmName() or "?") .. "/" .. name
    local g = d.guilds[key]
    if not g then g = {} d.guilds[key] = g end
    for _, k in ipairs(KIND_LIST) do g[k] = g[k] or {} end
    g.reminded = g.reminded or {}
    g.seq = g.seq or 0
    return g
end

function G.Char()
    local d = G.DB()
    local key = (GetRealmName and GetRealmName() or "?") .. "/" .. me()
    local c = d.chars[key]
    if not c then c = {} d.chars[key] = c end
    c.templates = c.templates or {}
    return c
end

-- a new record id: <name>.<time36><seq36>
function G.NewId()
    local g = G.GDB()
    g.seq = g.seq + 1
    return me() .. "." .. G.B36(now() - 1700000000) .. G.B36(g.seq)
end

-- the guild's shared settings (an officer sets them in Guild > Setup)
function G.Cfg()
    local c = G.GDB().cf.cfg
    if not c then c = { id = "cfg", by = "", u = 0, banker = "", orank = 1, tick = 10, council = 0 } end
    c.orank = tonumber(c.orank) or 1
    c.tick = tonumber(c.tick) or 10
    c.council = tonumber(c.council) or 0
    return c
end

-- -- Roster -----------------------------------------------------------------------------------

G.roster = {}      -- list of members (GetGuildRosterInfo order)
G.byName = {}      -- name -> member

function G:ScanRoster()
    local list, by = {}, {}
    if G.GuildName() and GetGuildRosterInfo then
        local n = GetNumGuildMembers and GetNumGuildMembers(true) or 0
        for i = 1, n do
            local name, rank, rankIndex, level, class, zone, note, onote, online = GetGuildRosterInfo(i)
            if name then
                local m = { name = name, rank = rank or "", rankIndex = rankIndex or 9, level = tonumber(level) or 0,
                    class = class, token = G.Token(class), zone = zone or "", note = note or "", onote = onote or "",
                    online = online and true or false, index = i }
                if not m.online and GetGuildRosterLastOnline then
                    local y, mo, d, h = GetGuildRosterLastOnline(i)
                    if y or mo or d or h then m.lastOnline = { y or 0, mo or 0, d or 0, h or 0 } end
                end
                tinsert(list, m)
                by[name] = m
            end
        end
    end
    -- our own rank comes from GetGuildInfo even before the roster arrives
    if G.GuildName() and not by[me()] then
        local _, rank, rankIndex = GetGuildInfo("player")
        local _, token = UnitClass("player")
        local m = { name = me(), rank = rank or "", rankIndex = rankIndex or 9, level = UnitLevel("player") or 0,
            token = token, class = CLASS_NAME[token or ""], zone = "", note = "", onote = "", online = true }
        by[me()] = m
    end
    self.roster, self.byName = list, by
    -- remember when we saw guild mates online (for "last seen" after they log off)
    local mi = G.GDB().mi
    for _, m in ipairs(list) do
        if m.online then
            local r = mi[m.name]
            if r then r.seen = now() end
        end
    end
    self.rosterAt = GetTime()
    self.dirty = true
end

function G:Member(name) return self.byName[name or ""] end

-- officer by rank: what the other clients check (the guild's officer rank from Guild > Setup)
function G:IsOfficerName(name)
    local m = self.byName[name or ""]
    if not m then return false end
    return m.rankIndex <= G.Cfg().orank
end

local function can(fn) local f = getglobal(fn) return f and f() and true or false end
function G:CanPromote() return can("CanGuildPromote") end
function G:CanDemote() return can("CanGuildDemote") end
function G:CanInvite() return can("CanGuildInvite") end
function G:CanOfficerNote() return can("CanEditOfficerNote") end
function G:CanPublicNote() return can("CanEditPublicNote") end
function G:CanViewOfficerNote() return can("CanViewOfficerNote") or can("CanEditOfficerNote") end
function G:CanMOTD() return can("CanEditMOTD") end
-- officer tools in the window: anyone who may edit officer notes or promote, or who holds an
-- officer rank by the guild's setting
function G:IsOfficer()
    if not G.GuildName() then return false end
    return self:CanOfficerNote() or self:CanPromote() or self:IsOfficerName(me())
end

-- the main character of an alt (or the name itself)
function G:MainOf(name)
    local l = G.GDB().al[name or ""]
    if l and not blank(l.main) and l.main ~= name then return l.main end
    return name
end
function G:AltsOf(main)
    local out = {}
    for alt, l in pairs(G.GDB().al) do
        if l.main == main and alt ~= main then tinsert(out, alt) end
    end
    table.sort(out)
    return out
end

-- -- Records ----------------------------------------------------------------------------------
-- Field order is the wire format: only ever append.

local KINDS = {
    ev = { "title", "start", "dur", "note", "del" },
    su = { "e", "name", "role", "st" },
    ap = { "name", "level", "class", "text", "t", "st", "note" },
    dk = { "t", "kind", "names", "amt", "reason", "item", "void" },
    bk = { "t", "kind", "who", "copper", "item", "count", "auto", "note", "void" },
    rq = { "who", "text", "t", "st" },
    al = { "alt", "main" },
    cf = { "banker", "orank", "tick", "council" },
    lc = { "item", "t", "open", "winner", "cost", "cands" },
    vo = { "sid", "voter", "cand" },
    mi = { "name", "profs", "pts", "recent", "lvl" },
}
G.KINDS = KINDS
local NUMERIC = { start = true, dur = true, del = true, level = true, t = true, amt = true, copper = true,
    count = true, auto = true, void = true, orank = true, tick = true, council = true, open = true, cost = true,
    pts = true, lvl = true, u = true }
local LIMIT = { title = 40, note = 120, text = 160, reason = 60, item = 60, names = 1200, profs = 80, recent = 60,
    cands = 200, main = 12, alt = 12, name = 12, who = 12, banker = 12, cand = 12, voter = 12, by = 12 }

local function clip(s, n) s = tostring(s or "") if n and strlen(s) > n then s = strsub(s, 1, n) end return s end

function G.Serialize(kind, rec)
    local parts = { kind, G.Esc(rec.id), G.Esc(rec.by), floor(tonumber(rec.u) or 0) }
    for _, f in ipairs(KINDS[kind]) do
        local v = rec[f]
        if v == nil then v = "" end
        tinsert(parts, G.Esc(clip(v, LIMIT[f])))
    end
    return table.concat(parts, ",")
end

function G.Deserialize(line)
    local f, n = W.Split(line, ",")
    local kind = f[1]
    local spec = KINDS[kind or ""]
    if not spec or n < 4 then return nil end
    local rec = { id = G.Unesc(f[2]), by = G.Unesc(f[3]), u = tonumber(f[4]) or 0 }
    if blank(rec.id) then return nil end
    for i, k in ipairs(spec) do
        local v = f[4 + i]
        if v ~= nil then
            v = clip(G.Unesc(v), LIMIT[k])
            if NUMERIC[k] then v = tonumber(v) end
            if v ~= "" then rec[k] = v end
        end
    end
    return kind, rec
end

-- May `author` have written this record? (`author` is rec.by; the sender is checked in Put.)
function G:Allowed(kind, rec)
    local by = rec.by or ""
    local officer = self:IsOfficerName(by)
    if kind == "ev" or kind == "ap" or kind == "dk" or kind == "cf" or kind == "lc" then return officer end
    if kind == "su" then return by == rec.name or officer end
    if kind == "bk" then
        if officer then return true end
        local banker = G.Cfg().banker
        return rec.auto == 1 and (by == rec.who or (not blank(banker) and by == banker))
    end
    if kind == "rq" then return officer or (by == rec.who and rec.st == "open") end
    if kind == "al" then return officer or by == rec.alt or by == rec.main end
    if kind == "vo" then return officer and by == rec.voter end
    if kind == "mi" then return by == rec.name end
    return false
end

G.listeners = {}
function G:OnChange(fn) tinsert(self.listeners, fn) end
local function changed(kind, rec, fromWire)
    G.dirty = true
    for _, fn in ipairs(G.listeners) do
        local ok, err = pcall(fn, kind, rec, fromWire)
        if not ok then W:Error(ID, err) end
    end
end

-- Store a record if it is newer. sender = nil for our own records. Returns true when kept.
function G:Put(kind, rec, sender)
    if not KINDS[kind] or not rec or blank(rec.id) then return false end
    if sender then
        if not self.byName[sender] then return false end                         -- not a guild mate
        if W.Ignore and W.Ignore.IsIgnored and W.Ignore.IsIgnored(sender) then return false end
        if sender ~= rec.by and not self:IsOfficerName(sender) then return false end   -- relays: officers only
        if not self.byName[rec.by or ""] and kind ~= "mi" then
            -- the author left the guild: only an officer's relay keeps it
            if not self:IsOfficerName(sender) then return false end
        elseif not self:Allowed(kind, rec) then
            return false
        end
    end
    -- applications stay with the officers who handle them
    if kind == "ap" and sender and not (self:IsOfficer() or self:CanInvite()) then return false end
    local t = G.GDB()[kind]
    local old = t[rec.id]
    if old and (tonumber(old.u) or 0) >= (tonumber(rec.u) or 0) then return false end
    if kind == "cf" and old and sender then
        -- only the guild master moves the officer rank line
        local a = self.byName[rec.by or ""]
        if not (a and a.rankIndex == 0) then rec.orank = old.orank end
    end
    if kind == "mi" and old then rec.seen = old.seen end
    t[rec.id] = rec
    changed(kind, rec, sender ~= nil)
    return true
end

-- Store our own record (u stamped newer than any copy) and send it to the guild.
function G:Publish(kind, rec)
    rec.by = me()
    local old = G.GDB()[kind][rec.id]
    local u = now()
    if old and (tonumber(old.u) or 0) >= u then u = (tonumber(old.u) or 0) + 1 end
    rec.u = u
    if not self:Put(kind, rec) then return false end
    self:SendRecords({ G.Serialize(kind, rec) })
    return true
end

-- -- Channel transport ------------------------------------------------------------------------

local outbox, sinceSend, msgSeq = {}, 0, 0
local inbox = {}
G.outbox = outbox

local function channelId()
    local id = GetChannelName and GetChannelName(CHANNEL)
    if id and id > 0 then return id end
end
G.ChannelId = channelId

function G:Join()
    if channelId() or not JoinChannelByName or not G.GuildName() then return end
    JoinChannelByName(CHANNEL)
    for i = 1, (NUM_CHAT_WINDOWS or 7) do
        local cf = getglobal("ChatFrame" .. i)
        if cf and ChatFrame_RemoveChannel then ChatFrame_RemoveChannel(cf, CHANNEL) end
    end
end

-- keep the carrier lines out of every chat window
if W.chatFilters then
    tinsert(W.chatFilters, function(ev)
        if ev ~= "CHAT_MSG_CHANNEL" and ev ~= "CHAT_MSG_CHANNEL_NOTICE"
            and ev ~= "CHAT_MSG_CHANNEL_JOIN" and ev ~= "CHAT_MSG_CHANNEL_LEAVE" then return false end
        local name = strlower(arg9 or arg4 or "")
        return strfind(name, strlower(CHANNEL), 1, 1) ~= nil
    end)
end

-- Send a payload (records joined by ';'), chunked.
function G:SendRecords(records)
    local gname = G.GuildName()
    if not gname or not records[1] then return end
    local key = G.GuildKey(gname)
    -- pack records into messages of at most ~8 lines each
    local msgs, cur = {}, ""
    for _, r in ipairs(records) do
        if cur ~= "" and strlen(cur) + strlen(r) + 1 > CHUNK * 8 then tinsert(msgs, cur) cur = "" end
        cur = (cur == "") and r or (cur .. ";" .. r)
    end
    if cur ~= "" then tinsert(msgs, cur) end
    for _, m in ipairs(msgs) do
        msgSeq = msgSeq + 1
        local mid = G.B36(msgSeq)
        local n = math.ceil(strlen(m) / CHUNK)
        if n < 1 then n = 1 end
        for i = 1, n do
            if getn(outbox) >= 600 then tremove(outbox, 1) end
            tinsert(outbox, "GH1~" .. key .. "~" .. mid .. "~" .. i .. "/" .. n .. "~" .. strsub(m, (i - 1) * CHUNK + 1, i * CHUNK))
        end
    end
end

function G:Flush(elapsed)
    sinceSend = sinceSend + (elapsed or 0)
    if sinceSend < SEND_GAP or not outbox[1] then return end
    local id = channelId()
    if not id then return end
    sinceSend = 0
    SendChatMessage(tremove(outbox, 1), "CHANNEL", nil, id)
end

function G:Receive(msg, sender)
    if not msg or blank(sender) or sender == me() then return end
    local _, _, key, mid, i, n, chunk = strfind(msg, "^GH1~([%w]+)~([%w]+)~(%d+)/(%d+)~(.*)$")
    if not key then return end
    local gname = G.GuildName()
    if not gname or key ~= G.GuildKey(gname) then return end
    if not self.byName[sender] then
        -- a new face: maybe the roster is stale; ask for a fresh one and drop the line
        if GuildRoster and GetTime() - (self.askedRoster or -100) > 10 then self.askedRoster = GetTime(); GuildRoster() end
        return
    end
    i, n = tonumber(i), tonumber(n)
    if n < 1 or n > 64 or i < 1 or i > n then return end
    local box = inbox[sender .. "/" .. mid]
    if not box then box = { n = n, parts = {}, got = 0 } inbox[sender .. "/" .. mid] = box end
    box.at = GetTime()
    if not box.parts[i] then box.parts[i] = chunk; box.got = box.got + 1 end
    if box.got < box.n then return end
    inbox[sender .. "/" .. mid] = nil
    local recs, rn = W.Split(table.concat(box.parts), ";")
    for j = 1, rn do self:HandleRecord(recs[j], sender) end
end

function G:ExpireInbox()
    local t = GetTime()
    for k, box in pairs(inbox) do if t - (box.at or 0) > INBOX_TTL then inbox[k] = nil end end
end

-- -- Sync -------------------------------------------------------------------------------------

G.pendingReplies = {}    -- requester/kind -> { at, kind, maxU, count, who }

local function maxU(kind)
    local m, n = 0, 0
    for _, r in pairs(G.GDB()[kind]) do
        n = n + 1
        if (tonumber(r.u) or 0) > m then m = tonumber(r.u) or 0 end
    end
    return m, n
end

-- ask the guild for whatever we missed while offline
function G:RequestSync()
    local recs = {}
    for _, k in ipairs(KIND_LIST) do
        local m, n = maxU(k)
        tinsert(recs, "Q," .. k .. "," .. m .. "," .. n)
    end
    self:SendRecords(recs)
    self.syncAsked = GetTime()
end

function G:HandleRecord(line, sender)
    if blank(line) then return end
    local head = strsub(line, 1, 2)
    if head == "Q," then
        local f = W.Split(line, ",")
        local kind = f[2]
        if not KINDS[kind or ""] or not self:IsOfficer() then return end
        local key = sender .. "/" .. kind
        if not self.pendingReplies[key] then
            self.pendingReplies[key] = { at = GetTime() + 0.5 + math.random() * 2.5, kind = kind,
                maxU = tonumber(f[3]) or 0, count = tonumber(f[4]) or 0, who = sender }
        end
        return
    elseif head == "R," then
        local f = W.Split(line, ",")
        if f[2] and f[3] then self.pendingReplies[G.Unesc(f[2]) .. "/" .. f[3]] = nil end
        return
    end
    local kind, rec = G.Deserialize(line)
    if kind then self:Put(kind, rec, sender) end
end

function G:AnswerSyncs()
    local t = GetTime()
    for key, p in pairs(self.pendingReplies) do
        if t >= p.at then
            self.pendingReplies[key] = nil
            local list, older = {}, 0
            for _, r in pairs(G.GDB()[p.kind]) do
                if (tonumber(r.u) or 0) > p.maxU - SKEW then tinsert(list, r) else older = older + 1 end
            end
            if older > p.count then
                -- they are missing old records too: send everything
                list = {}
                for _, r in pairs(G.GDB()[p.kind]) do tinsert(list, r) end
            end
            if list[1] then
                table.sort(list, function(a, b) return (tonumber(a.u) or 0) < (tonumber(b.u) or 0) end)
                local recs = { "R," .. G.Esc(p.who) .. "," .. p.kind }
                for _, r in ipairs(list) do tinsert(recs, G.Serialize(p.kind, r)) end
                self:SendRecords(recs)
            end
        end
    end
end

-- -- Member info: professions and achievement points ------------------------------------------

local PROFESSIONS = {
    Alchemy = true, Blacksmithing = true, Enchanting = true, Engineering = true, Herbalism = true,
    Leatherworking = true, Mining = true, Skinning = true, Tailoring = true, Cooking = true,
    ["First Aid"] = true, Fishing = true,
}
G.PROFESSIONS = PROFESSIONS

function G.MyProfessions()
    local out = {}
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local name, header, _, rank = GetSkillLineInfo(i)
            if name and not header and PROFESSIONS[name] then tinsert(out, { name = name, rank = tonumber(rank) or 0 }) end
        end
    end
    table.sort(out, function(a, b) if a.rank ~= b.rank then return a.rank > b.rank end return a.name < b.name end)
    local s = {}
    for _, p in ipairs(out) do tinsert(s, p.name .. " " .. p.rank) end
    return table.concat(s, ", ")
end

function G.MyAchievements()
    local A = Achievements
    if not (A and A.Points and A.Recent) then return nil, nil end
    local pts = A.Points()
    local recent = {}
    for _, a in ipairs(A.Recent(3)) do tinsert(recent, a.id .. ":" .. (A.earned[a.id] or 0)) end
    return pts, table.concat(recent, "/")
end

function G:PublishInfo(force)
    if not G.GuildName() then return end
    local pts, recent = G.MyAchievements()
    local rec = { id = me(), name = me(), profs = G.MyProfessions(), pts = pts, recent = recent, lvl = UnitLevel("player") }
    local old = G.GDB().mi[me()]
    if not force and old and old.profs == rec.profs and old.pts == rec.pts and old.recent == rec.recent
        and old.lvl == rec.lvl and now() - (tonumber(old.u) or 0) < 1800 then return end
    self:Publish("mi", rec)
end

-- the hook Social's guild tab already calls for its roster rows
function G:Professions(name)
    local r = G.GDB().mi[name or ""]
    return r and r.profs or nil
end
if Concord then
    function Concord:GetProfessions(name) return G:Professions(name) end
end

-- -- Events -----------------------------------------------------------------------------------

local ev = CreateFrame("Frame", "GuildHub_Events")
G.eventFrame = ev
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "CHAT_MSG_CHANNEL", "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE",
    "CHAT_MSG_WHISPER", "CHAT_MSG_OFFICER", "CHAT_MSG_COMBAT_HOSTILE_DEATH", "CHAT_MSG_SYSTEM", "UI_INFO_MESSAGE",
    "TRADE_SHOW", "TRADE_CLOSED", "TRADE_MONEY_CHANGED", "TRADE_ACCEPT_UPDATE", "TRADE_PLAYER_ITEM_CHANGED",
    "TRADE_TARGET_ITEM_CHANGED", "SKILL_LINES_CHANGED", "PLAYER_LEVEL_UP", "GUILD_MOTD" }) do
    ev:RegisterEvent(e)
end
G.handlers = {}   -- event -> list of fn (Data.lua adds)
function G:On(e, fn)
    self.handlers[e] = self.handlers[e] or {}
    tinsert(self.handlers[e], fn)
end

ev:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        G.joinAt = GetTime() + JOIN_DELAY
        if GuildRoster then GuildRoster() end
        G:ScanRoster()
    elseif event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        G:ScanRoster()
        if event == "PLAYER_GUILD_UPDATE" and G.GuildName() and not channelId() then G.joinAt = GetTime() + 1 end
    elseif event == "CHAT_MSG_CHANNEL" then
        if strfind(strlower(arg9 or arg4 or ""), strlower(CHANNEL), 1, 1) then
            if W:IsActive(ID) then G:Receive(arg1 or "", arg2) end
            return
        end
    elseif event == "SKILL_LINES_CHANGED" or event == "PLAYER_LEVEL_UP" then
        G.infoAt = GetTime() + 5
    end
    local list = G.handlers[event]
    if list and W:IsActive(ID) then
        for _, fn in ipairs(list) do
            local ok, err = pcall(fn)
            if not ok then W:Error(ID, err) end
        end
    end
end)

local acc, slow = 0, 0
ev:SetScript("OnUpdate", function()
    local dt = arg1 or 0
    if not W:IsActive(ID) then return end
    G:Flush(dt)
    acc = acc + dt
    if acc < 0.5 then return end
    acc = 0
    local t = GetTime()
    if G.joinAt and t >= G.joinAt then
        G.joinAt = nil
        G:Join()
        G.helloAt = t + 1
    end
    if G.helloAt and t >= G.helloAt and channelId() then
        G.helloAt = nil
        G:PublishInfo(true)
        G:RequestSync()
    end
    if G.infoAt and t >= G.infoAt then G.infoAt = nil; G:PublishInfo() end
    G:AnswerSyncs()
    slow = slow + 0.5
    if slow >= 5 then
        slow = 0
        G:ExpireInbox()
        if G.Tick then G:Tick() end
        -- a fresh roster now and then (last online, ranks), and our info every half hour
        if GuildRoster and G.GuildName() and t - (G.rosterAt or 0) > 120 then G.rosterAt = t; GuildRoster() end
        if channelId() then G:PublishInfo() end
    end
    if G.dirty and G.Render then G.dirty = false; G:Render() end
end)
