--[[
    GuildHub/Data.lua  -  what the tabs do: roster actions, applications, events and reminders,
    the bank log (manual and from the trade window with the banker), requests, DKP with raid
    ticks and loot, the loot council, the MOTD composer and the guild achievements summary.
    The window (Window.lua) only draws these; the sim tests drive them directly too.
]]--

local W = WenillaCore
local UI = W.UI
local G = GuildHub
local ID = G.ID

local strfind, strsub, strgsub, strlen, strlower = string.find, string.sub, string.gsub, string.len, string.lower
local tinsert, tremove, getn = table.insert, table.remove, table.getn
local floor = math.floor
local me, now, blank = G.Me, G.Now, G.Blank
local DOT = G.DOT

local function setting(key, default) return W:Setting(ID, key, default) end
local function toast(opts)
    if not setting("toasts", true) then return end
    opts.duration = opts.duration or 8
    UI.Toast(opts)
end
G.ToastIf = toast

local function split(s, sep)
    local out = {}
    if blank(s) then return out end
    local f, n = W.Split(s, sep)
    for i = 1, n do if f[i] ~= "" then tinsert(out, f[i]) end end
    return out
end
G.SplitList = split

-- -- Roster actions ---------------------------------------------------------------------------

function G:MyRank()
    local m = self:Member(me())
    return m and m.rankIndex or 99
end

function G:CanPromoteMember(m)
    -- one step up, never to your own rank or above
    return m and m.name ~= me() and self:CanPromote() and (m.rankIndex - 1) > self:MyRank()
end
function G:CanDemoteMember(m)
    local n = GuildControlGetNumRanks and GuildControlGetNumRanks() or 10
    return m and m.name ~= me() and self:CanDemote() and m.rankIndex > self:MyRank() and m.rankIndex < n - 1
end

function G:Promote(name)
    local m = self:Member(name)
    if not self:CanPromoteMember(m) then return false end
    GuildPromoteByName(name)
    if GuildRoster then GuildRoster() end
    return true
end
function G:Demote(name)
    local m = self:Member(name)
    if not self:CanDemoteMember(m) then return false end
    GuildDemoteByName(name)
    if GuildRoster then GuildRoster() end
    return true
end

function G:SetNote(name, text, officer)
    local m = self:Member(name)
    if not (m and m.index) then return false end
    text = strsub(W.Trim(text or ""), 1, 31)
    if officer then
        if not (self:CanOfficerNote() and GuildRosterSetOfficerNote) then return false end
        GuildRosterSetOfficerNote(m.index, text)
        m.onote = text
    else
        if not (self:CanPublicNote() and GuildRosterSetPublicNote) then return false end
        GuildRosterSetPublicNote(m.index, text)
        m.note = text
    end
    self.dirty = true
    if GuildRoster then GuildRoster() end
    return true
end

-- alt links: anyone links their own characters, officers any member
function G:LinkAlt(alt, main)
    alt, main = W.Trim(alt or ""), W.Trim(main or "")
    if blank(alt) or alt == main then return false end
    if not (self:IsOfficer() or alt == me() or main == me()) then return false end
    return self:Publish("al", { id = alt, alt = alt, main = main })
end
function G:UnlinkAlt(alt)
    if not G.GDB().al[alt or ""] then return false end
    if not (self:IsOfficer() or alt == me() or G.GDB().al[alt].main == me()) then return false end
    return self:Publish("al", { id = alt, alt = alt, main = "" })
end

function G:LastOnline(m)
    if m.online then return "Online" end
    local lo = m.lastOnline
    if lo then
        local y, mo, d, h = lo[1], lo[2], lo[3], lo[4]
        if y > 0 then return y .. " year" .. (y == 1 and "" or "s") .. " ago" end
        if mo > 0 then return mo .. " month" .. (mo == 1 and "" or "s") .. " ago" end
        if d > 0 then return d .. " day" .. (d == 1 and "" or "s") .. " ago" end
        if h > 0 then return h .. " hour" .. (h == 1 and "" or "s") .. " ago" end
        return "under an hour ago"
    end
    local r = G.GDB().mi[m.name]
    return (r and G.Ago(r.seen)) or "Offline"
end

-- the roster as the window lists it: search over name, rank, notes, zone, professions, main
function G:RosterItems(query, showOffline, sort)
    local q = strlower(W.Trim(query or ""))
    local items = {}
    for _, m in ipairs(self.roster) do
        local main = self:MainOf(m.name)
        local hay = strlower(m.name .. " " .. m.rank .. " " .. m.note .. " " .. (m.onote or "") .. " " .. m.zone .. " "
            .. (self:Professions(m.name) or "") .. " " .. (m.class or "") .. " " .. (main ~= m.name and main or ""))
        if (showOffline ~= false or m.online) and (q == "" or strfind(hay, q, 1, true)) then tinsert(items, m) end
    end
    sort = sort or "rank"
    table.sort(items, function(a, b)
        if sort == "name" then return a.name < b.name end
        if sort == "level" and a.level ~= b.level then return a.level > b.level end
        if a.online ~= b.online then return a.online end
        if a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
        return a.name < b.name
    end)
    return items
end

function G:RosterExport()
    local lines = { "Name,Level,Class,Rank,Main,Professions,Last online,Note" }
    for _, m in ipairs(self:RosterItems("", true, "name")) do
        local main = self:MainOf(m.name)
        local function q(s) s = tostring(s or "") if strfind(s, "[,\"]") then s = "\"" .. strgsub(s, "\"", "\"\"") .. "\"" end return s end
        tinsert(lines, table.concat({ q(m.name), m.level, q(G.CLASS_NAME[m.token or ""] or m.class or ""), q(m.rank),
            q(main ~= m.name and main or ""), q(self:Professions(m.name) or ""), q(self:LastOnline(m)), q(m.note) }, ","))
    end
    return table.concat(lines, "\n")
end

-- -- Guild settings -----------------------------------------------------------------------------

function G:SetCfg(fields)
    if not self:IsOfficer() then return false end
    local c = G.Cfg()
    local rec = { id = "cfg", banker = c.banker, orank = c.orank, tick = c.tick, council = c.council }
    for k, v in pairs(fields) do rec[k] = v end
    if rec.orank ~= c.orank and self:MyRank() ~= 0 then rec.orank = c.orank end
    return self:Publish("cf", rec)
end

-- -- Applications (the Guilds board's apply whisper) ------------------------------------------
--   "[Guilds] Hi! I'd like to join <Guild>. Level 12 hunter."

function G:ParseApplication(msg)
    if strsub(msg or "", 1, 9) ~= "[Guilds] " then return nil end
    local _, _, guild = strfind(msg, "<(.-)>")
    local _, _, level, class = strfind(msg, "Level (%d+) (%a*)")
    return guild, tonumber(level), class
end

function G:OnWhisper(msg, from)
    local guild, level, class = self:ParseApplication(msg)
    if not guild or blank(from) or guild ~= G.GuildName() then return end
    if not (self:CanInvite() or self:IsOfficer()) then return end
    if W.Ignore and W.Ignore.IsIgnored and W.Ignore.IsIgnored(from) then return end
    if self:Member(from) then return end
    local token = G.Token(class)
    local old = G.GDB().ap[from]
    self:Publish("ap", { id = from, name = from, level = level, class = token or class, text = strsub(msg, 10),
        t = now(), st = "new", note = old and old.note or nil })
    toast({ icon = "Interface\\Icons\\INV_Letter_15", title = "Guild application", text = from .. (level and (", level " .. level) or "")
        .. (token and (" " .. G.CLASS_NAME[token]) or "") .. ". Open Guild Hub > Recruit.",
        onClick = function() if G.Show then G:Show("recruit", "apps") end end })
    if G.ui and G.ui.SetUnread then G.ui.SetUnread("recruit") end
end
G:On("CHAT_MSG_WHISPER", function() G:OnWhisper(arg1, arg2) end)

function G:Applications(filter)
    local out = {}
    for _, a in pairs(G.GDB().ap) do
        if filter == "all" or (filter == "done" and a.st ~= "new") or ((filter or "new") == "new" and a.st == "new") then tinsert(out, a) end
    end
    table.sort(out, function(a, b) return (a.t or 0) > (b.t or 0) end)
    return out
end

local function updateApp(id, fields)
    local a = G.GDB().ap[id or ""]
    if not a then return false end
    local rec = {}
    for k, v in pairs(a) do rec[k] = v end
    for k, v in pairs(fields) do rec[k] = v end
    return G:Publish("ap", rec)
end

function G:AcceptApp(id)
    local a = G.GDB().ap[id or ""]
    if not a or not self:CanInvite() then return false end
    if Social and Social.GuildInvite then Social:GuildInvite(a.name) else GuildInviteByName(a.name) end
    return updateApp(id, { st = "accepted" })
end
function G:DeclineApp(id)
    local a = G.GDB().ap[id or ""]
    if not a or not (self:CanInvite() or self:IsOfficer()) then return false end
    if setting("declineWhisper", true) then
        SendChatMessage("[Guild Hub] Thanks for applying to <" .. (G.GuildName() or "") .. ">. We can't take you on right now - good luck out there!",
            "WHISPER", nil, a.name)
    end
    return updateApp(id, { st = "declined" })
end
function G:NoteApp(id, note)
    if not (self:CanInvite() or self:IsOfficer()) then return false end
    return updateApp(id, { note = strsub(W.Trim(note or ""), 1, 120) })
end

-- -- Events -----------------------------------------------------------------------------------

G.ROLES = { { key = "t", label = "Tank" }, { key = "h", label = "Healer" }, { key = "d", label = "Damage" } }
G.ROLE_LABEL = { t = "Tank", h = "Healer", d = "Damage" }

-- midnight of the Monday of this week (+ offset weeks)
function G.WeekStart(offset)
    local d = date("*t", now())
    local back = G.Mod(d.wday + 5, 7)       -- Monday = 0
    return time({ year = d.year, month = d.month, day = d.day - back + 7 * (offset or 0), hour = 0, min = 0, sec = 0 })
end
function G.DayStart(t)
    local d = date("*t", t)
    return time({ year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0 })
end

function G.EventTime(e)
    return date("%a %d %b %H:%M", e.start or 0)
end

function G:CreateEvent(title, start, dur, note)
    if not self:IsOfficer() then return nil end
    title = strsub(W.Trim(title or ""), 1, 40)
    start = tonumber(start)
    if blank(title) or not start then return nil end
    local id = G.NewId()
    self:Publish("ev", { id = id, title = title, start = start, dur = tonumber(dur) or 120, note = strsub(W.Trim(note or ""), 1, 120), del = 0 })
    return id
end
function G:DeleteEvent(id)
    local e = G.GDB().ev[id or ""]
    if not e or not self:IsOfficer() then return false end
    local rec = {}
    for k, v in pairs(e) do rec[k] = v end
    rec.del = 1
    return self:Publish("ev", rec)
end

-- events between two times (deleted ones left out), oldest first
function G:EventsBetween(a, b)
    local out = {}
    for _, e in pairs(G.GDB().ev) do
        if (e.del or 0) == 0 and e.start and e.start >= a and e.start < b then tinsert(out, e) end
    end
    table.sort(out, function(x, y) if x.start ~= y.start then return x.start < y.start end return x.id < y.id end)
    return out
end
function G:NextEvent()
    local list = self:EventsBetween(now(), now() + 86400 * 60)
    return list[1]
end

function G:SignUp(eid, role, st)
    local e = G.GDB().ev[eid or ""]
    if not e or (e.del or 0) ~= 0 then return false end
    if st ~= "yes" and st ~= "tent" and st ~= "no" then st = "yes" end
    if not G.ROLE_LABEL[role or ""] then role = "d" end
    return self:Publish("su", { id = eid .. "/" .. me(), e = eid, name = me(), role = role, st = st })
end
function G:Signups(eid)
    local out = {}
    for _, s in pairs(G.GDB().su) do if s.e == eid then tinsert(out, s) end end
    local order = { yes = 1, tent = 2, no = 3 }
    table.sort(out, function(a, b)
        if a.st ~= b.st then return (order[a.st] or 9) < (order[b.st] or 9) end
        if a.role ~= b.role then return (a.role or "") > (b.role or "") end   -- tanks, healers, damage
        return a.name < b.name
    end)
    return out
end
function G:MySignup(eid) return G.GDB().su[(eid or "") .. "/" .. me()] end

function G:SignupCounts(eid)
    local c = { yes = 0, tent = 0, no = 0, t = 0, h = 0, d = 0 }
    for _, s in ipairs(self:Signups(eid)) do
        c[s.st] = (c[s.st] or 0) + 1
        if s.st == "yes" then c[s.role] = (c[s.role] or 0) + 1 end
    end
    return c
end

function G:EventLine(e)
    local c = self:SignupCounts(e.id)
    local hours = floor((e.dur or 120) / 60 * 10 + 0.5) / 10
    return "[Guild Hub] " .. e.title .. " - " .. G.EventTime(e) .. " (" .. hours .. " h). " .. c.yes .. " signed up ("
        .. c.t .. " tank, " .. c.h .. " heal, " .. c.d .. " dps)" .. (c.tent > 0 and (", " .. c.tent .. " tentative") or "")
        .. ". Sign up: /gh events"
end
function G:PostEvent(eid, chan)
    local e = G.GDB().ev[eid or ""]
    if not e then return false end
    SendChatMessage(strgsub(self:EventLine(e), "|", "/"), chan or "GUILD")
    return true
end

-- toasts 30 and 5 minutes before an event (not for events you declined)
function G:CheckReminders()
    if not setting("reminders", true) then return end
    local g, t = G.GDB(), now()
    for _, e in pairs(g.ev) do
        if (e.del or 0) == 0 and e.start and e.start > t then
            local mine = self:MySignup(e.id)
            if not (mine and mine.st == "no") then
                -- the closest mark we have passed; logging in 4 min before shows only the 5 min one
                for _, mins in ipairs({ 5, 30 }) do
                    local key = e.id .. "/" .. mins
                    if t >= e.start - mins * 60 then
                        if g.reminded[key] then break end
                        g.reminded[key] = t
                        g.reminded[e.id .. "/30"] = g.reminded[e.id .. "/30"] or t
                        local left = floor((e.start - t) / 60 + 0.5)
                        toast({ icon = "Interface\\Icons\\INV_Misc_PocketWatch_01", title = e.title .. " in " .. left .. " min",
                            text = G.EventTime(e) .. (mine and (" " .. DOT .. " you: " .. (mine.st == "tent" and "tentative" or G.ROLE_LABEL[mine.role])) or " " .. DOT .. " not signed up"),
                            color = { 0.45, 0.85, 1 }, sound = setting("toastSound", true) and "RaidWarning" or nil,
                            onClick = function() if G.Show then G:Show("events") G:SelectEvent(e.id) end end })
                        W.Print("Guild Hub: " .. e.title .. " starts in " .. left .. " min (" .. G.EventTime(e) .. ").")
                        break
                    end
                end
            end
        end
    end
    -- forget reminders for events long gone
    for key, at in pairs(g.reminded) do if t - at > 86400 * 2 then g.reminded[key] = nil end end
end

-- -- Bank log -----------------------------------------------------------------------------------

function G:Banker() local b = G.Cfg().banker return not blank(b) and b or nil end

function G:BankAdd(kind, who, copper, item, count, note, auto, id)
    if kind ~= "dep" and kind ~= "wd" and kind ~= "purse" then return false end
    if not auto and not self:IsOfficer() then return false end
    copper = floor(tonumber(copper) or 0)
    item = W.Trim(item or "")
    if copper <= 0 and blank(item) and kind ~= "purse" then return false end
    return self:Publish("bk", { id = id or G.NewId(), t = now(), kind = kind, who = W.Trim(who or me()), copper = copper,
        item = item ~= "" and item or nil, count = tonumber(count) or (item ~= "" and 1 or nil), auto = auto and 1 or 0,
        note = note and strsub(W.Trim(note), 1, 120) or nil, void = 0 })
end
function G:BankVoid(id)
    local b = G.GDB().bk[id or ""]
    if not b or not self:IsOfficer() then return false end
    local rec = {}
    for k, v in pairs(b) do rec[k] = v end
    rec.void = 1
    return self:Publish("bk", rec)
end

-- newest first, with the running balance after each entry
function G:BankLog()
    local list = {}
    for _, b in pairs(G.GDB().bk) do if b.kind ~= "purse" then tinsert(list, b) end end
    table.sort(list, function(a, b) if (a.t or 0) ~= (b.t or 0) then return (a.t or 0) < (b.t or 0) end return a.id < b.id end)
    local bal = 0
    for _, b in ipairs(list) do
        if (b.void or 0) == 0 then
            if b.kind == "dep" then bal = bal + (b.copper or 0) else bal = bal - (b.copper or 0) end
        end
        b.balance = bal
    end
    local out = {}
    for i = getn(list), 1, -1 do tinsert(out, list[i]) end
    return out, bal
end
function G:Purse()
    for _, b in pairs(G.GDB().bk) do if b.kind == "purse" then return b end end
end

-- the trade window: a trade with the banker (or, on the banker, with a guild mate) is logged
-- when it completes. Both sides may log the same trade; the id is the same on both, so it merges.
local trade = nil
G.trade = function() return trade end

local function tradeItems(fn)
    local out = {}
    if not fn then return out end
    for i = 1, 6 do
        local name, _, count = fn(i)
        if name and name ~= "" then tinsert(out, { name = name, count = tonumber(count) or 1 }) end
    end
    return out
end

local function snapshot()
    if not trade then return end
    trade.give = GetPlayerTradeMoney and GetPlayerTradeMoney() or 0
    trade.get = GetTargetTradeMoney and GetTargetTradeMoney() or 0
    trade.giveItems = tradeItems(GetTradePlayerItemInfo)
    trade.getItems = tradeItems(GetTradeTargetItemInfo)
end

G:On("TRADE_SHOW", function()
    trade = nil
    local banker = G:Banker()
    if not banker or not setting("autoBank", true) then return end
    local partner = UnitName("NPC")
    if blank(partner) then return end
    if partner == banker or (me() == banker and G:Member(partner)) then
        trade = { partner = partner, mineBanker = (me() == banker) }
        snapshot()
    end
end)
for _, e in ipairs({ "TRADE_MONEY_CHANGED", "TRADE_ACCEPT_UPDATE", "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED" }) do
    G:On(e, function() if trade and not trade.closed then snapshot() end end)
end
G:On("TRADE_CLOSED", function()
    if trade then trade.closed = GetTime() end
end)

function G:TradeComplete()
    local tr = trade
    trade = nil
    if not tr then return end
    local who = tr.mineBanker and tr.partner or me()
    -- what reached the banker is a deposit, what left the banker a withdrawal
    local depMoney, wdMoney = tr.give, tr.get
    local depItems, wdItems = tr.giveItems, tr.getItems
    if tr.mineBanker then depMoney, wdMoney, depItems, wdItems = tr.get, tr.give, tr.getItems, tr.giveItems end
    local bucket = G.B36(floor(now() / 300))
    local function idOf(kind, what) return "tr." .. bucket .. "." .. who .. "." .. kind .. "." .. strgsub(what, "[^%w]", "") end
    local n = 0
    if (depMoney or 0) > 0 then self:BankAdd("dep", who, depMoney, nil, nil, "trade", true, idOf("d", tostring(depMoney))); n = n + 1 end
    if (wdMoney or 0) > 0 then self:BankAdd("wd", who, wdMoney, nil, nil, "trade", true, idOf("w", tostring(wdMoney))); n = n + 1 end
    for _, it in ipairs(depItems or {}) do self:BankAdd("dep", who, 0, it.name, it.count, "trade", true, idOf("d", it.name .. it.count)); n = n + 1 end
    for _, it in ipairs(wdItems or {}) do self:BankAdd("wd", who, 0, it.name, it.count, "trade", true, idOf("w", it.name .. it.count)); n = n + 1 end
    if n > 0 then W.Print("Guild Hub: logged the trade with " .. tr.partner .. " in the bank log (" .. n .. " entr" .. (n == 1 and "y" or "ies") .. ").") end
    if me() == G:Banker() then G.purseAt = GetTime() + 2 end
end

local TRADE_DONE = "Trade complete."
local function tradeDone(msg)
    local want = ERR_TRADE_COMPLETE or TRADE_DONE
    return msg == want or msg == TRADE_DONE
end
G:On("UI_INFO_MESSAGE", function() if tradeDone(arg1) then G:TradeComplete() end end)
G:On("CHAT_MSG_SYSTEM", function() if tradeDone(arg1) then G:TradeComplete() end end)

-- the banker's own client reports the purse it really holds
function G:PublishPurse()
    if me() ~= self:Banker() or not GetMoney then return end
    local p = self:Purse()
    if p and p.copper == GetMoney() and now() - (p.u or 0) < 3600 then return end
    self:BankAdd("purse", me(), GetMoney(), nil, nil, nil, true, "purse")
end

-- requests: anyone asks the bank for something; officers mark them done or declined
function G:Request(text)
    text = strsub(W.Trim(text or ""), 1, 160)
    if blank(text) or not G.GuildName() then return false end
    return self:Publish("rq", { id = G.NewId(), who = me(), text = text, t = now(), st = "open" })
end
function G:ResolveRequest(id, st)
    local r = G.GDB().rq[id or ""]
    if not r or not self:IsOfficer() or (st ~= "done" and st ~= "declined" and st ~= "open") then return false end
    local rec = {}
    for k, v in pairs(r) do rec[k] = v end
    rec.st = st
    return self:Publish("rq", rec)
end
function G:Requests(showDone)
    local out = {}
    for _, r in pairs(G.GDB().rq) do if showDone or r.st == "open" then tinsert(out, r) end end
    table.sort(out, function(a, b)
        if (a.st == "open") ~= (b.st == "open") then return a.st == "open" end
        return (a.t or 0) > (b.t or 0)
    end)
    return out
end

-- -- DKP --------------------------------------------------------------------------------------
-- dk entries: kind "tick" (raid attendance), "award" / "adjust" (+/- points to names), "loot"
-- (cost taken from the winner). Points belong to mains: an alt's points go to its main.

G.BOSSES = {
    -- Molten Core, Onyxia, Blackwing Lair, Zul'Gurub, Ruins and Temple of Ahn'Qiraj, Naxxramas
    ["Lucifron"] = 1, ["Magmadar"] = 1, ["Gehennas"] = 1, ["Garr"] = 1, ["Baron Geddon"] = 1, ["Shazzrah"] = 1,
    ["Sulfuron Harbinger"] = 1, ["Golemagg the Incinerator"] = 1, ["Majordomo Executus"] = 1, ["Ragnaros"] = 1,
    ["Onyxia"] = 1,
    ["Razorgore the Untamed"] = 1, ["Vaelastrasz the Corrupt"] = 1, ["Broodlord Lashlayer"] = 1, ["Firemaw"] = 1,
    ["Ebonroc"] = 1, ["Flamegor"] = 1, ["Chromaggus"] = 1, ["Nefarian"] = 1,
    ["High Priestess Jeklik"] = 1, ["High Priest Venoxis"] = 1, ["High Priestess Mar'li"] = 1, ["Bloodlord Mandokir"] = 1,
    ["High Priest Thekal"] = 1, ["High Priestess Arlokk"] = 1, ["Jin'do the Hexxer"] = 1, ["Hakkar"] = 1,
    ["Kurinnaxx"] = 1, ["General Rajaxx"] = 1, ["Moam"] = 1, ["Buru the Gorger"] = 1, ["Ayamiss the Hunter"] = 1, ["Ossirian the Unscarred"] = 1,
    ["The Prophet Skeram"] = 1, ["Battleguard Sartura"] = 1, ["Fankriss the Unyielding"] = 1, ["Princess Huhuran"] = 1,
    ["Viscidus"] = 1, ["Ouro"] = 1, ["C'Thun"] = 1,
    ["Anub'Rekhan"] = 1, ["Grand Widow Faerlina"] = 1, ["Maexxna"] = 1, ["Noth the Plaguebringer"] = 1,
    ["Heigan the Unclean"] = 1, ["Loatheb"] = 1, ["Instructor Razuvious"] = 1, ["Gothik the Harvester"] = 1,
    ["Patchwerk"] = 1, ["Grobbulus"] = 1, ["Gluth"] = 1, ["Thaddius"] = 1, ["Sapphiron"] = 1, ["Kel'Thuzad"] = 1,
}

function G:AddDKP(kind, names, amt, reason, item, id)
    if not self:IsOfficer() then return false end
    if kind ~= "tick" and kind ~= "award" and kind ~= "adjust" and kind ~= "loot" then return false end
    amt = tonumber(amt)
    if not amt or not names or not names[1] then return false end
    local seen, list = {}, {}
    for _, n in ipairs(names) do
        local m = self:MainOf(W.Trim(n))
        if not blank(m) and not seen[m] then seen[m] = true; tinsert(list, m) end
    end
    table.sort(list)
    return self:Publish("dk", { id = id or G.NewId(), t = now(), kind = kind, names = table.concat(list, ":"), amt = amt,
        reason = reason and strsub(W.Trim(reason), 1, 60) or nil, item = item and strsub(W.Trim(item), 1, 60) or nil, void = 0 })
end
function G:VoidDKP(id)
    local d = G.GDB().dk[id or ""]
    if not d or not self:IsOfficer() then return false end
    local rec = {}
    for k, v in pairs(d) do rec[k] = v end
    rec.void = 1
    return self:Publish("dk", rec)
end

-- the names in the raid right now (online), or nil when not in a raid
function G:RaidNames()
    local n = GetNumRaidMembers and GetNumRaidMembers() or 0
    if n == 0 then return nil end
    local out = {}
    for i = 1, n do
        local name, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
        if name and online then tinsert(out, name) end
    end
    return out
end

function G:TickRaid(reason, id)
    local names = self:RaidNames()
    if not names then return false end
    return self:AddDKP("tick", names, G.Cfg().tick, reason or "Attendance", nil, id)
end

G:On("CHAT_MSG_COMBAT_HOSTILE_DEATH", function()
    local _, _, boss = strfind(arg1 or "", "^(.+) dies%.$")
    if not boss or not G.BOSSES[boss] or not setting("autoTicks", true) or not G:IsOfficer() then return end
    -- one id per boss per half hour, so every officer's client logs the same tick once
    local id = "boss." .. strgsub(boss, "[^%w]", "") .. "." .. G.B36(floor(now() / 1800))
    if G.GDB().dk[id] then return end
    if G:TickRaid(boss, id) then W.Print("Guild Hub: " .. boss .. " - " .. G.Cfg().tick .. " DKP to the raid.") end
end)

function G:AwardLoot(winner, item, cost)
    winner = W.Trim(winner or "")
    if blank(winner) or blank(item) then return false end
    return self:AddDKP("loot", { winner }, tonumber(cost) or 0, "Loot", item)
end

function G:DKPEntries()
    local out = {}
    for _, d in pairs(G.GDB().dk) do tinsert(out, d) end
    table.sort(out, function(a, b) if (a.t or 0) ~= (b.t or 0) then return (a.t or 0) > (b.t or 0) end return a.id > b.id end)
    return out
end

function G:Standings()
    local by, list = {}, {}
    local function row(n)
        local r = by[n]
        if not r then r = { name = n, pts = 0, earned = 0, spent = 0, ticks = 0, items = 0 } by[n] = r tinsert(list, r) end
        return r
    end
    for _, d in pairs(G.GDB().dk) do
        if (d.void or 0) == 0 then
            for _, n in ipairs(split(d.names, ":")) do
                local r = row(self:MainOf(n))
                local a = d.amt or 0
                if d.kind == "loot" then
                    r.pts = r.pts - a; r.spent = r.spent + a; r.items = r.items + 1
                else
                    r.pts = r.pts + a
                    if a > 0 then r.earned = r.earned + a end
                    if d.kind == "tick" then r.ticks = r.ticks + 1 end
                end
            end
        end
    end
    table.sort(list, function(a, b) if a.pts ~= b.pts then return a.pts > b.pts end return a.name < b.name end)
    return list
end
function G:Points(name)
    local main = self:MainOf(name)
    for _, r in ipairs(self:Standings()) do if r.name == main then return r.pts end end
    return 0
end

function G:DKPExport(history)
    local lines = {}
    if history then
        tinsert(lines, "Date,Kind,Names,Points,Reason,Item,Void")
        for _, d in ipairs(self:DKPEntries()) do
            tinsert(lines, date("%Y-%m-%d %H:%M", d.t or 0) .. "," .. (d.kind or "") .. "," .. strgsub(d.names or "", ":", " ") .. ","
                .. (d.amt or 0) .. "," .. strgsub(d.reason or "", ",", " ") .. "," .. strgsub(d.item or "", ",", " ") .. "," .. ((d.void or 0) == 1 and "yes" or ""))
        end
    else
        tinsert(lines, "Name,Points,Earned,Spent,Raids,Items")
        for _, r in ipairs(self:Standings()) do
            tinsert(lines, r.name .. "," .. r.pts .. "," .. r.earned .. "," .. r.spent .. "," .. r.ticks .. "," .. r.items)
        end
    end
    return table.concat(lines, "\n")
end

-- -- Loot council -----------------------------------------------------------------------------

function G:OpenVote(item, cands)
    if not self:IsOfficer() or blank(item) then return nil end
    local id = G.NewId()
    local list = cands or self:RaidNames() or {}
    self:Publish("lc", { id = id, item = strsub(W.Trim(item), 1, 60), t = now(), open = 1, cands = table.concat(list, ":") })
    return id
end
function G:Vote(sid, cand)
    local s = G.GDB().lc[sid or ""]
    if not s or (s.open or 0) ~= 1 or not self:IsOfficer() or blank(cand) then return false end
    return self:Publish("vo", { id = sid .. "/" .. me(), sid = sid, voter = me(), cand = W.Trim(cand) })
end
function G:Tally(sid)
    local by, list = {}, {}
    for _, v in pairs(G.GDB().vo) do
        if v.sid == sid and not blank(v.cand) then
            local r = by[v.cand]
            if not r then r = { cand = v.cand, n = 0, voters = {} } by[v.cand] = r tinsert(list, r) end
            r.n = r.n + 1
            tinsert(r.voters, v.voter)
        end
    end
    table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.cand < b.cand end)
    for _, r in ipairs(list) do table.sort(r.voters) end
    return list
end
function G:CloseVote(sid, winner, cost)
    local s = G.GDB().lc[sid or ""]
    if not s or (s.open or 0) ~= 1 or not self:IsOfficer() then return false end
    if blank(winner) then local t = self:Tally(sid) winner = t[1] and t[1].cand end
    local rec = {}
    for k, v in pairs(s) do rec[k] = v end
    rec.open, rec.winner, rec.cost = 0, winner or "", tonumber(cost) or 0
    self:Publish("lc", rec)
    if not blank(winner) then self:AwardLoot(winner, s.item, cost) end
    return true
end
function G:Votes(showClosed)
    local out = {}
    for _, s in pairs(G.GDB().lc) do if showClosed or (s.open or 0) == 1 then tinsert(out, s) end end
    table.sort(out, function(a, b) return (a.t or 0) > (b.t or 0) end)
    return out
end

-- -- MOTD -------------------------------------------------------------------------------------

G.TEMPLATES = {
    "Raid tonight: {next}. Sign up in /gh!",
    "Welcome to <{guild}>! Say hi in guild chat and check /gh for events.",
    "Bank: send mats to {banker}; ask for items in /gh > Bank > Requests.",
    "Guild meeting {next}. Bring ideas!",
}

function G:FillTemplate(s)
    local e = self:NextEvent()
    local repl = {
        next = e and (e.title .. " " .. G.EventTime(e)) or "(no event planned)",
        guild = G.GuildName() or "", banker = self:Banker() or "the guild banker",
        date = date("%a %d %b", now()), me = me(),
    }
    local out = strgsub(s or "", "{(%a+)}", function(k) return repl[k] or ("{" .. k .. "}") end)
    return out
end
function G:Templates()
    local out = {}
    for _, t in ipairs(G.TEMPLATES) do tinsert(out, { text = t, builtin = true }) end
    for _, t in ipairs(G.Char().templates) do tinsert(out, { text = t }) end
    return out
end
function G:SaveTemplate(text)
    text = W.Trim(text or "")
    if blank(text) then return false end
    for _, t in ipairs(G.Char().templates) do if t == text then return false end end
    tinsert(G.Char().templates, text)
    while getn(G.Char().templates) > 20 do tremove(G.Char().templates, 1) end
    return true
end
function G:DeleteTemplate(text)
    local list = G.Char().templates
    for i = getn(list), 1, -1 do if list[i] == text then tremove(list, i) return true end end
    return false
end
function G:SetMOTD(text)
    if not self:CanMOTD() or not GuildSetMOTD then return false end
    text = strsub(strgsub(self:FillTemplate(text), "|", "/"), 1, 128)
    GuildSetMOTD(text)
    return true
end

-- -- Officer chat ---------------------------------------------------------------------------

G.officerLines = {}
G:On("CHAT_MSG_OFFICER", function()
    tinsert(G.officerLines, { from = arg2 or "?", text = arg1 or "", t = now() })
    while getn(G.officerLines) > 50 do tremove(G.officerLines, 1) end
    G.dirty = true
end)
function G:SendOfficer(text)
    text = W.Trim(text or "")
    if blank(text) or not self:CanViewOfficerNote() then return false end
    SendChatMessage(strgsub(text, "|", "/"), "OFFICER")
    return true
end

-- -- Guild achievements summary ---------------------------------------------------------------

function G:AchievementSummary()
    local total, members, recent = 0, {}, {}
    local A = Achievements
    for name, r in pairs(G.GDB().mi) do
        if self:Member(name) then
            local pts = tonumber(r.pts)
            if pts then total = total + pts; tinsert(members, { name = name, pts = pts }) end
            for _, pair in ipairs(split(r.recent, "/")) do
                local _, _, aid, t = strfind(pair, "^(%d+):(%d+)$")
                aid, t = tonumber(aid), tonumber(t)
                local a = A and A.Get and A.Get(aid)
                if a then tinsert(recent, { name = name, a = a, t = t }) end
            end
        end
    end
    table.sort(members, function(a, b) if a.pts ~= b.pts then return a.pts > b.pts end return a.name < b.name end)
    table.sort(recent, function(a, b) if a.t ~= b.t then return a.t > b.t end return a.name < b.name end)
    return total, members, recent
end

-- -- Housekeeping (every 5 s from Core) -----------------------------------------------------

function G:Tick()
    self:CheckReminders()
    if self.purseAt and GetTime() >= self.purseAt then self.purseAt = nil; self:PublishPurse() end
    if not self.purseChecked or GetTime() - self.purseChecked > 300 then self.purseChecked = GetTime(); self:PublishPurse() end
    -- a trade that closed without "Trade complete." was cancelled
    local tr = trade
    if tr and tr.closed and GetTime() - tr.closed > 3 then trade = nil end
end

-- new records from the guild that deserve a toast
G:OnChange(function(kind, rec, fromWire)
    -- records replayed by a login sync are old news: only fresh ones toast
    if not fromWire or now() - (tonumber(rec.u) or 0) > 300 then return end
    if kind == "ev" and (rec.del or 0) == 0 and rec.start and rec.start > now() then
        if setting("toastEvents", true) then
            toast({ icon = "Interface\\Icons\\INV_Misc_Note_02", title = "New guild event", text = G.Plain(rec.title) .. " " .. DOT .. " " .. G.EventTime(rec),
                onClick = function() if G.Show then G:Show("events") G:SelectEvent(rec.id) end end })
        end
        if G.ui and G.ui.SetUnread then G.ui.SetUnread("events") end
    elseif kind == "lc" and (rec.open or 0) == 1 and G:IsOfficer() then
        toast({ icon = "Interface\\Icons\\INV_Misc_Bag_10", title = "Loot council", text = "Vote on " .. G.Plain(rec.item) .. ".",
            onClick = function() if G.Show then G:Show("dkp", "council") end end })
    elseif kind == "rq" and rec.st == "open" and G:IsOfficer() then
        if G.ui and G.ui.SetUnread then G.ui.SetUnread("bank") end
    elseif kind == "ap" and rec.st == "new" and G.ui and G.ui.SetUnread then
        G.ui.SetUnread("recruit")
    end
end)
