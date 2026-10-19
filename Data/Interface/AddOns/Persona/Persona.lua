--[[
    Persona  (Classic+ / Open Vanilla roleplay profiles)

    Every player can write a profile and read anyone else's on the same realm:
      identity  roleplay name, title, pronouns, age, height & build, home, motto, crest icon,
                roleplay experience
      story     what they're doing right now, appearance, a longer bio
      shares    up to five short quotes, hooks, rumours or notes
      OOC       an out-of-character "currently" line and an account-wide note (all characters)
      listening what you are listening to ("Title - Artist", 80 characters), only when you switched
                on "Share what I'm listening to" in the launcher or on the web page (off by default)

      /rp  or  /persona            open your target's profile, or your own
      /rp <name>                   view a player's profile
      /rp edit | list              edit your own / browse every profile you've seen
      /rp ic | ooc | lfrp | st     set your status (in character, out of character,
                                   looking for roleplay, storytelling)
      Mouse over a player          tooltip: roleplay name, title, status, a glance line, "currently"
      Target a player              a status badge on their portrait; click it to read their Persona
      Right-click a player         "View Persona"
      Minimap button               left-click your Persona, right-click cycles your status

    Settings live in /addons (Classic+ addon manager) when WenillaCore is loaded.

    Storage (SavedVariables Persona_DB, account-wide):
      Persona_DB.mine[realm][character]   your profiles, one per character
      Persona_DB.author                   your account-wide OOC note
      Persona_DB.cache[realm][name]       other players' profiles, kept 60 days after last seen
      Persona_DB.minimap                  minimap button angle

    Transport: a hidden custom chat channel (PERSONA_CHANNEL); its lines and join notices are
    filtered out of every chat window. Requests are tiny and throttled; a profile is sent only
    when the asker's cached revision is stale. Nothing needs server support.
      ?P <target> <knownRev>                       "send me <target>'s profile if newer"
      !P <rev> <i>/<n> <payload chunk>             one chunk of the sender's serialized profile
      #P <rev> <status> <name>~<title>             a one-line summary, broadcast on login/save
    Payloads carry no spaces (the server trims and collapses spaces in chat lines), no '|'
    (chat link escapes) and no newlines; see esc() below.

    Lua 5.0 rules (1.12.1 client): no '#' length operator, no '%' operator, handlers read
    this/event/arg1..arg9.
]]--

Persona = Persona or {}
local P = Persona
P.version = "1.2.0"

local PERSONA_CHANNEL = "OWPersona"
local CHUNK = 200                  -- payload bytes per channel line (lines max out at 255)
local SEND_GAP = 0.7               -- seconds between our own channel lines
local REQUEST_GAP = 30             -- don't re-ask about the same player more often than this
local RESEND_GAP = 12              -- don't send our full profile more often than this
local JOIN_RETRY = 10
local INBOX_TTL = 60               -- drop half-received profiles after this many seconds
local CACHE_DAYS = 60
local LIMITS = {
    name = 48, title = 60, pronouns = 24, age = 24, build = 40, home = 48, motto = 90,
    currently = 120, occur = 120, appearance = 400, bio = 2400, share = 200, author = 200,
    pic = 40, look = 24, listening = 80,
}
-- Order is the wire format: only ever append, so older copies ignore the new fields.
local FIELDS = { "name", "title", "status", "currently", "appearance", "bio", "author",
    "s1", "s2", "s3", "s4", "s5",
    "pronouns", "age", "build", "home", "motto", "exp", "crest", "occur", "pic", "look",
    "listening" }
local STATUS_ORDER = { "ic", "ooc", "lfrp", "st" }
local STATUS_TEXT = {
    ic = "|cff40ff40In character|r", ooc = "|cffff8040Out of character|r",
    lfrp = "|cff40c0ffLooking for roleplay|r", st = "|cffd8a0ffStorytelling|r",
}
-- the same, readable on the parchment page
local STATUS_INK = {
    ic = "|cff1d7a1dIn character|r", ooc = "|cffa04a10Out of character|r",
    lfrp = "|cff1a62a0Looking for roleplay|r", st = "|cff6a2a9aStorytelling|r",
}
local STATUS_SHORT = { ic = "IC", ooc = "OOC", lfrp = "LFRP", st = "Story" }
local STATUS_ART = { ic = "Persona_IC", ooc = "Persona_OOC", lfrp = "Persona_LFRP", st = "Persona_ST" }
local STATUS_RGB = { ic = { 0.25, 1, 0.25 }, ooc = { 1, 0.5, 0.25 }, lfrp = { 0.25, 0.75, 1 }, st = { 0.85, 0.63, 1 } }
local EXP_TEXT = { ["1"] = "New to roleplay", ["2"] = "Casual roleplayer", ["3"] = "Experienced roleplayer", ["4"] = "Happy to guide newcomers" }
local CRESTS = {
    "Persona", "INV_Misc_Book_09", "INV_Sword_04", "INV_Shield_06", "Spell_Holy_HolyBolt",
    "Spell_Shadow_ShadowBolt", "Spell_Nature_StarFall", "Spell_Fire_Fire", "Spell_Frost_FrostBolt02",
    "Spell_Nature_Regeneration", "Ability_Hunter_Pet_Wolf", "INV_Misc_Note_01", "INV_Misc_Coin_01",
    "INV_Misc_Map_01", "INV_Shirt_GuildTabard_01", "Ability_Warrior_BattleShout", "Spell_Nature_NullifyPoison",
    "INV_Misc_Bag_10",
}
local ICON_FALLBACK = "Interface\\Icons\\INV_Misc_Book_09"
local DOT = "\194\183"             -- middle dot (UTF-8)

local strsub, strlen, strfind, strgsub, strlower = string.sub, string.len, string.find, string.gsub, string.lower
local tinsert, tremove, getn = table.insert, table.remove, table.getn

local function Print(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffd8a0ffPersona|r " .. msg) end
end

local function realm() return (GetRealmName and GetRealmName()) or "?" end
local function me() return (UnitName and UnitName("player")) or "?" end
local function now() return (time and time()) or 0 end
local function blank(s) return not s or s == "" end

-- -- Suite integration (WenillaCore is optional) --------------------------------------

local function W() return WenillaCore end
local function active()
    local w = W()
    if w and w.IsActive then return w:IsActive("Persona") end
    return true
end
local function setting(key, default)
    local w = W()
    if w and w.Setting then return w:Setting("Persona", key, default) end
    return default
end
-- custom art when it loads (TGA beside WenillaCore, or BLP streamed on the web), else a stock file
local function art(tex, name, fallback)
    local w = W()
    if w and w.Art then return w:Art(tex, name, fallback) end
    tex:SetTexture(fallback)
    return false
end
local function crestTexture(tex, crest)
    if blank(crest) or crest == "Persona" then
        art(tex, "Persona_Icon", ICON_FALLBACK)
        tex:SetTexCoord(0, 1, 0, 1)
    else
        tex:SetTexture("Interface\\Icons\\" .. crest)
        tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end
end

-- -- Encoding --------------------------------------------------------------------------
-- \ -> \\   _ -> \u   space -> _   newline -> \n   | -> \p   ~ -> \t
-- '~' separates fields; the result has no spaces, pipes or newlines.

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
        if c == "n" then return "\n" elseif c == "p" then return "|" elseif c == "t" then return "~"
        elseif c == "u" then return "_" end
        return c
    end)
    return s
end

-- Text from other players is shown literally: '||' renders as one '|', so no colours, links or
-- fake system lines can be smuggled in.
local function clean(s)
    local r = strgsub(s or "", "|", "||")
    return r
end

local function clip(s, n)
    s = s or ""
    if strlen(s) > n then s = strsub(s, 1, n) end
    return s
end

local function serialize(p)
    local out = {}
    for _, k in ipairs(FIELDS) do tinsert(out, esc(p[k] or "")) end
    return table.concat(out, SEP)
end

local validPic, validLook   -- the picture checks (Pictures, below)

local function deserialize(s)
    local p, i, start = {}, 1, 1
    while true do
        local a = strfind(s, SEP, start, true)
        local piece = a and strsub(s, start, a - 1) or strsub(s, start)
        local k = FIELDS[i]
        if k then
            local v = unesc(piece)
            p[k] = LIMITS[k] and clip(v, LIMITS[k]) or clip(v, 2400)
        end
        if not a then break end
        start, i = a + 1, i + 1
    end
    if not STATUS_TEXT[p.status or ""] then p.status = "ooc" end
    if p.crest and not strfind(p.crest, "^[%w_]+$") then p.crest = "" end
    if p.exp and not EXP_TEXT[p.exp] then p.exp = "" end
    if not validPic(p.pic) then p.pic = "" end
    if p.look and p.look ~= "" and not validLook(p.look) then p.look = "" end
    return p
end

-- -- Database ----------------------------------------------------------------------------

local function db()
    if type(Persona_DB) ~= "table" then Persona_DB = {} end
    local d = Persona_DB
    d.mine = d.mine or {}
    d.cache = d.cache or {}
    d.author = d.author or ""
    d.mine[realm()] = d.mine[realm()] or {}
    d.cache[realm()] = d.cache[realm()] or {}
    return d
end

function P.Mine()
    local d = db()
    local p = d.mine[realm()][me()]
    if not p then
        p = { name = "", title = "", status = "ooc", currently = "", appearance = "", bio = "", rev = 0 }
        d.mine[realm()][me()] = p
    end
    p.author = d.author
    return p
end

local demo = {}    -- sample profiles while the Classic+ demo stream runs (never saved)

function P.Get(name)
    if not name then return nil end
    if name == me() then return P.Mine() end
    return db().cache[realm()][name] or demo[name]
end

-- the name to show: the roleplay name when one is set
function P.DisplayName(p, fallback)
    if p and not blank(p.name) then return p.name end
    return fallback
end

-- -- Now playing ---------------------------------------------------------------------------
-- The launcher (desktop) or the page (web, realm/www/nowplaying.js) hands us "Title - Artist".
-- Web: ow/nowplaying.js calls Persona.SetListening(text) live, every change. Desktop: the launcher
-- writes this character's SavedVariablesPerCharacter file, Persona_NowPlaying = { text=, at= };
-- the client reads it when the character enters the world (a /reload re-reads the copy the client
-- itself saved a moment before, so it does not pick up a newer song). A desktop value is shown for
-- LISTEN_TTL seconds after it was written, since nothing can refresh it during the session.
local LISTEN_TTL = 600
local listenUntil = nil

local announce   -- defined below (Transport)

function P.SetListening(text, ttl, quiet)
    text = string.gsub(text or "", "[%c|]", " ")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    text = clip(text, LIMITS.listening)
    local p = P.Mine()
    listenUntil = (text ~= "" and ttl) and (now() + ttl) or nil
    if (p.listening or "") == text then return false end
    p.listening = text
    p.rev = (p.rev or 0) + 1
    -- quiet: at load, before the channels are joined (the login announce carries the new rev)
    if announce and not quiet then announce() end
    return true
end

-- what to show for a profile's listening field ("" when none)
function P.Listening(p)
    if not p or blank(p.listening) or not setting("showListening", true) then return "" end
    return p.listening
end

local function readNowPlayingShim()
    local np = type(Persona_NowPlaying) == "table" and Persona_NowPlaying or {}
    local at = tonumber(np.at) or 0
    if type(np.text) == "string" and np.text ~= "" and now() - at < LISTEN_TTL then
        P.SetListening(np.text, LISTEN_TTL - (now() - at), true)
    elseif (P.Mine().listening or "") ~= "" then
        P.SetListening("", nil, true)
    end
end

local function prune()
    local cutoff = now() - CACHE_DAYS * 86400
    for _, list in pairs(db().cache) do
        for name, p in pairs(list) do
            if (p.seen or 0) < cutoff then list[name] = nil end
        end
    end
end

local function ignored(name)
    if not GetNumIgnores then return false end
    for i = 1, GetNumIgnores() do
        if GetIgnoreName(i) == name then return true end
    end
    return false
end

-- -- Channel transport ------------------------------------------------------------------

local channelId = nil
local outbox = {}
local sinceSend = 0
local lastJoin = -100
local lastFull = -100
local asked = {}       -- name -> time we last asked
local inbox = {}       -- sender -> { rev, n, parts = {}, got, at }

local function channel()
    if channelId and channelId > 0 and GetChannelName then
        local id = GetChannelName(PERSONA_CHANNEL)
        if id and id > 0 then channelId = id return id end
    end
    local id = GetChannelName and GetChannelName(PERSONA_CHANNEL)
    if id and id > 0 then channelId = id return id end
    channelId = nil
    return nil
end

-- Opened a few seconds after entering the world (joinWait), so a line queued before then
-- (flush) can't join early and take one of the stock channels' numbers.
local joinOpen = false
local function join()
    if channel() or not joinOpen then return end
    if GetTime and GetTime() - lastJoin < JOIN_RETRY then return end
    lastJoin = GetTime and GetTime() or 0
    -- No frame id: the channel isn't added to any chat window; the filter below also hides
    -- its lines and "Joined Channel" notices in case a window lists every channel.
    if JoinChannelByName then JoinChannelByName(PERSONA_CHANNEL) end
end

local function send(line)
    if getn(outbox) > 60 then tremove(outbox, 1) end
    tinsert(outbox, line)
end

local function flush(elapsed)
    sinceSend = sinceSend + (elapsed or 0)
    if sinceSend < SEND_GAP or getn(outbox) == 0 then return end
    local id = channel()
    if not id then join() return end
    sinceSend = 0
    SendChatMessage(tremove(outbox, 1), "CHANNEL", nil, id)
end

local function queueProfile()
    local t = GetTime and GetTime() or 0
    if t - lastFull < RESEND_GAP then return end
    lastFull = t
    local p = P.Mine()
    local data = serialize(p)
    local n = math.ceil(strlen(data) / CHUNK)
    if n < 1 then n = 1 end
    -- Drop any older copy of our profile still waiting, so a burst of saves sends one.
    local keep = {}
    for _, l in ipairs(outbox) do if strsub(l, 1, 2) ~= "!P" then tinsert(keep, l) end end
    outbox = keep
    for i = 1, n do
        send("!P " .. (p.rev or 0) .. " " .. i .. "/" .. n .. " " .. strsub(data, (i - 1) * CHUNK + 1, i * CHUNK))
    end
end

announce = function()
    if not active() then return end
    local p = P.Mine()
    send("#P " .. (p.rev or 0) .. " " .. (p.status or "ooc") .. " "
        .. esc(clip(p.name, LIMITS.name)) .. SEP .. esc(clip(p.title, LIMITS.title)))
end

function P.Request(name)
    if not active() or blank(name) or name == me() or demo[name] then return end
    local t = now()
    if asked[name] and t - asked[name] < REQUEST_GAP then return end
    asked[name] = t
    local known = db().cache[realm()][name]
    send("?P " .. name .. " " .. ((known and known.rev) or -1))
end

local refreshTooltip, refreshBadge   -- defined below

local function onChannel(msg, sender)
    if not msg or blank(sender) or sender == me() or ignored(sender) then return end
    local kind = strsub(msg, 1, 2)
    if kind == "?P" then
        if not active() then return end
        local _, _, target, rev = strfind(msg, "^%?P (%S+) (%-?%d+)")
        if target == me() and tonumber(rev) ~= (P.Mine().rev or 0) then queueProfile() end
    elseif kind == "#P" then
        local _, _, rev, status, rest = strfind(msg, "^#P (%d+) (%a+) ?(%S*)")
        if not rev then return end
        if not STATUS_TEXT[status] then status = "ooc" end
        local nm, title = "", rest or ""
        local a = strfind(title, SEP, 1, true)
        if a then nm, title = strsub(title, 1, a - 1), strsub(title, a + 1) end
        nm, title = clip(unesc(nm), LIMITS.name), clip(unesc(title), LIMITS.title)
        local c = db().cache[realm()]
        local p = c[sender]
        rev = tonumber(rev)
        if p then
            p.seen = now()
            if rev ~= p.rev then p.status = status; p.title = title; p.name = nm; p.stale = true end
        else
            c[sender] = { name = nm, rev = -1, status = status, title = title, seen = now(), stale = true }
        end
        refreshTooltip(sender); refreshBadge()
        if P.listShown then P.RefreshList() end
    elseif kind == "!P" then
        local _, _, rev, i, n, chunk = strfind(msg, "^!P (%d+) (%d+)/(%d+) (%S*)$")
        if not rev then return end
        rev, i, n = tonumber(rev), tonumber(i), tonumber(n)
        if n > 64 or i < 1 or i > n then return end   -- a full profile of escaped text is at most ~46
        local box = inbox[sender]
        if not box or box.rev ~= rev or box.n ~= n then box = { rev = rev, n = n, parts = {}, got = 0 } inbox[sender] = box end
        box.at = now()
        if not box.parts[i] then box.parts[i] = chunk; box.got = box.got + 1 end
        if box.got == n then
            local p = deserialize(table.concat(box.parts))
            p.rev, p.seen, p.stale = rev, now(), nil
            p.author = clip(p.author or "", LIMITS.author)
            db().cache[realm()][sender] = p
            inbox[sender] = nil
            if P.viewing == sender then P.ShowView(sender) end
            refreshTooltip(sender); refreshBadge()
            if P.listShown then P.RefreshList() end
        end
    end
end

local function expireInbox()
    local t = now()
    for k, box in pairs(inbox) do
        if t - (box.at or 0) > INBOX_TTL then inbox[k] = nil end
    end
end

-- Hide the transport channel from every chat window.
local function isOurChannel()
    local a, b = arg9 or "", arg4 or ""
    return strfind(strlower(a), "owpersona", 1, true) or strfind(strlower(b), "owpersona", 1, true)
end
if ChatFrame_OnEvent then
    local origChat = ChatFrame_OnEvent
    ChatFrame_OnEvent = function(ev)
        local e = ev or event
        if e and strsub(e, 1, 16) == "CHAT_MSG_CHANNEL" and isOurChannel() then return end
        return origChat(ev)
    end
end

-- -- Tooltip --------------------------------------------------------------------------------

local tipFor = nil

local function glance(p)
    local bits = {}
    for _, k in ipairs({ "pronouns", "age", "build", "home" }) do
        if not blank(p[k]) then tinsert(bits, clean(p[k])) end
    end
    return table.concat(bits, " " .. DOT .. " ")
end

local function decorateTooltip()
    if not active() or not setting("showTooltip", true) then return end
    if not UnitIsPlayer or not UnitIsPlayer("mouseover") then return end
    local name = UnitName("mouseover")
    if not name or ignored(name) then return end
    if tipFor == name then return end
    local p = P.Get(name)
    if not p or (p.stale and name ~= me()) then P.Request(name) end
    if not p then return end
    if name == me() and blank(p.name) and blank(p.title) and blank(p.currently) then return end
    tipFor = name
    if setting("rpNames", true) and not blank(p.name) and p.name ~= name and GameTooltipTextLeft1 then
        GameTooltipTextLeft1:SetText(clean(p.name))
    end
    if not blank(p.title) then GameTooltip:AddLine("<" .. clean(p.title) .. ">", 0.85, 0.65, 1) end
    if p.status and STATUS_TEXT[p.status] then GameTooltip:AddLine(STATUS_TEXT[p.status]) end
    local g = glance(p)
    if g ~= "" then GameTooltip:AddLine(g, 0.8, 0.8, 0.8) end
    if not blank(p.currently) then GameTooltip:AddLine("Currently: " .. clean(p.currently), 1, 1, 1, 1) end
    if not blank(p.occur) then GameTooltip:AddLine("OOC: " .. clean(p.occur), 0.6, 0.6, 0.6, 1) end
    if P.Listening(p) ~= "" then GameTooltip:AddLine("Listening: " .. clean(P.Listening(p)), 0.6, 0.85, 1, 1) end
    if not blank(p.exp) and p.exp == "1" then GameTooltip:AddLine(EXP_TEXT["1"], 0.55, 0.85, 0.55) end
    if name ~= me() then GameTooltip:AddLine("/rp " .. name .. " to read their Persona", 0.5, 0.5, 0.5) end
    GameTooltip:Show()
end

-- a profile arrived for the player under the mouse: rebuild the tooltip with it
refreshTooltip = function(name)
    if not GameTooltip or not GameTooltip:IsVisible() then return end
    if not UnitExists or not UnitExists("mouseover") or UnitName("mouseover") ~= name then return end
    tipFor = nil
    GameTooltip:SetUnit("mouseover")
    decorateTooltip()
    if Social and Social.LiveTooltip then Social.LiveTooltip() end
end

if GameTooltip then
    local origHide = GameTooltip:GetScript("OnHide")
    GameTooltip:SetScript("OnHide", function()
        tipFor = nil
        if origHide then origHide() end
    end)
end

-- -- Target badge ---------------------------------------------------------------------------

local badge
local function buildBadge()
    if badge or not TargetFrame then return badge end
    badge = CreateFrame("Button", "PersonaTargetBadge", TargetFrame)
    badge:SetWidth(26); badge:SetHeight(26)
    if TargetPortrait then
        badge:SetPoint("CENTER", TargetPortrait, "BOTTOMLEFT", 6, 6)
    else
        badge:SetPoint("TOPRIGHT", TargetFrame, "TOPRIGHT", -10, -6)
    end
    badge:SetFrameLevel(TargetFrame:GetFrameLevel() + 5)
    local gem = badge:CreateTexture(nil, "ARTWORK")
    gem:SetAllPoints(badge)
    badge.gem = gem
    badge:RegisterForClicks("LeftButtonUp")
    badge:SetScript("OnClick", function() if UnitName("target") then P.ShowView(UnitName("target")) end end)
    badge:SetScript("OnEnter", function()
        local n = UnitName("target")
        local p = n and P.Get(n)
        local live = n and Social and Social.IsLive and Social:IsLive(n)
        if not p and not live then return end
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        if not p then
            GameTooltip:SetText(n, 1, 1, 1)
            GameTooltip:AddLine(Social.LIVE_TAG .. "|cffffd8d0  streaming now|r")
            GameTooltip:AddLine("Watch: " .. (Social.WATCH_URL or "openvanilla.app/streamers.html"), 0.6, 0.6, 0.65)
            GameTooltip:Show()
            return
        end
        GameTooltip:SetText(clean(P.DisplayName(p, n)), 0.85, 0.65, 1)
        if live then GameTooltip:AddLine(Social.LIVE_TAG .. "|cffffd8d0  streaming now|r") end
        if not blank(p.title) then GameTooltip:AddLine("<" .. clean(p.title) .. ">", 1, 1, 1) end
        if STATUS_TEXT[p.status or ""] then GameTooltip:AddLine(STATUS_TEXT[p.status]) end
        GameTooltip:AddLine("Click to read their Persona", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
    badge:Hide()
    return badge
end

refreshBadge = function()
    local b = buildBadge()
    if not b then return end
    local n = UnitIsPlayer and UnitIsPlayer("target") and UnitName("target")
    local p = n and P.Get(n)
    local live = n and Social and Social.IsLive and Social:IsLive(n)
    if not active() or not setting("targetBadge", true) or ignored(n) or (not p and not live)
        or (not live and n == me() and blank(p.name) and blank(p.title) and blank(p.bio)) then
        b:Hide()
        return
    end
    if live then                 -- streaming now: the Live badge instead of the status gem
        if not art(b.gem, "Persona_Live", "Interface\\Icons\\Spell_Holy_MindVision") then b.gem:SetVertexColor(1, 0.35, 0.3)
        else b.gem:SetVertexColor(1, 1, 1) end
        b:Show()
        return
    end
    local s = STATUS_TEXT[p.status or ""] and p.status or "ooc"
    if not art(b.gem, STATUS_ART[s], ICON_FALLBACK) then
        local c = STATUS_RGB[s]
        b.gem:SetVertexColor(c[1], c[2], c[3])
    else
        b.gem:SetVertexColor(1, 1, 1)
    end
    b:Show()
end

-- -- Minimap button -------------------------------------------------------------------------

local mm
local function placeMinimap()
    if not mm or not Minimap then return end
    local a = math.rad(db().minimap or 200)
    mm:ClearAllPoints()
    mm:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
end

local function cycleStatus()
    local cur = P.Mine().status or "ooc"
    local nxt = STATUS_ORDER[1]
    for i, s in ipairs(STATUS_ORDER) do
        if s == cur then nxt = STATUS_ORDER[i + 1] or STATUS_ORDER[1] end
    end
    P.SetStatus(nxt)
end

local function buildMinimap()
    if mm or not Minimap then return mm end
    mm = CreateFrame("Button", "PersonaMinimapButton", Minimap)
    mm:SetWidth(31); mm:SetHeight(31)
    mm:SetFrameStrata("MEDIUM")
    mm:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    mm:RegisterForDrag("LeftButton")
    local icon = mm:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(20); icon:SetHeight(20)
    icon:SetPoint("CENTER", mm, "CENTER", 0, 1)
    art(icon, "Persona_Icon", ICON_FALLBACK)
    local border = mm:CreateTexture(nil, "OVERLAY")
    border:SetWidth(52); border:SetHeight(52)
    border:SetPoint("TOPLEFT", mm, "TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    local dot = mm:CreateTexture(nil, "OVERLAY")
    dot:SetWidth(12); dot:SetHeight(12)
    dot:SetPoint("BOTTOMRIGHT", mm, "BOTTOMRIGHT", -3, 3)
    mm.dot = dot
    mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    mm:SetScript("OnClick", function()
        if arg1 == "RightButton" then cycleStatus() else P.ToggleMine() end
    end)
    mm:SetScript("OnDragStart", function() this.dragging = true end)
    mm:SetScript("OnDragStop", function() this.dragging = nil end)
    mm:SetScript("OnUpdate", function()
        if not this.dragging then return end
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local s = Minimap:GetEffectiveScale()
        db().minimap = math.deg(math.atan2(cy / s - my, cx / s - mx))
        placeMinimap()
    end)
    mm:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Persona", 0.85, 0.65, 1)
        GameTooltip:AddLine("Status: " .. (STATUS_TEXT[P.Mine().status or "ooc"] or ""))
        GameTooltip:AddLine("Left-click: your Persona", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Right-click: change status", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag: move this button", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    mm:SetScript("OnLeave", function() GameTooltip:Hide() end)
    placeMinimap()
    return mm
end

local function refreshMinimap()
    local b = buildMinimap()
    if not b then return end
    if not active() or not setting("minimapButton", true) then b:Hide() return end
    local s = P.Mine().status or "ooc"
    if not art(b.dot, STATUS_ART[s], nil) then
        local c = STATUS_RGB[s] or STATUS_RGB.ooc
        b.dot:SetTexture(c[1], c[2], c[3], 1)
    end
    b:Show()
end

-- -- Pictures --------------------------------------------------------------------------------
-- A profile picture is one short string on the wire (field "pic"):
--   ""                 your character's portrait when they're in view, else their race and sex
--   "me"               the same, chosen on purpose
--   "race:Female-Human" one of the client's own race portraits (TemporaryPortrait-*)
--   "npc:<icon>"       a face from the client's icon set (heroes and creatures)
--   "crest"            the crest icon (the older emblem field)
-- "look" carries the character's sex and race ("Female-Human") so a reader who can't see the
-- character still gets the right face. Everything here is a stock 1.12 file; nothing ships.

local PORTRAIT_DIR = "Interface\\CharacterFrame\\TemporaryPortrait-"
local RACES = { "Human", "Dwarf", "NightElf", "Gnome", "Orc", "Scourge", "Tauren", "Troll" }
local RACE_NAMES = { Human = "Human", Dwarf = "Dwarf", NightElf = "Night elf", Gnome = "Gnome", Orc = "Orc",
    Scourge = "Forsaken", Tauren = "Tauren", Troll = "Troll" }
local NPC_FACES = {
    { "INV_Misc_Head_Human_01", "Human" }, { "INV_Misc_Head_Human_02", "Human" },
    { "INV_Misc_Head_Dwarf_01", "Dwarf" }, { "INV_Misc_Head_Dwarf_02", "Dwarf" },
    { "INV_Misc_Head_Elf_01", "Elf" }, { "INV_Misc_Head_Elf_02", "Elf" },
    { "INV_Misc_Head_Gnome_01", "Gnome" }, { "INV_Misc_Head_Gnome_02", "Gnome" },
    { "INV_Misc_Head_Orc_01", "Orc" }, { "INV_Misc_Head_Orc_02", "Orc" },
    { "INV_Misc_Head_Troll_01", "Troll" }, { "INV_Misc_Head_Troll_02", "Troll" },
    { "INV_Misc_Head_Tauren_01", "Tauren" }, { "INV_Misc_Head_Tauren_02", "Tauren" },
    { "INV_Misc_Head_Undead_01", "Forsaken" }, { "INV_Misc_Head_Undead_02", "Forsaken" },
    { "INV_Misc_Head_Scourge_01", "Scourge" }, { "INV_Misc_Head_02", "Wanderer" },
    { "INV_Misc_Head_Kobold_01", "Kobold" }, { "INV_Misc_Head_Murloc_01", "Murloc" },
    { "INV_Misc_Head_Gnoll_01", "Gnoll" }, { "INV_Misc_Head_Quillboar_01", "Quilboar" },
    { "INV_Misc_Head_Centaur_01", "Centaur" }, { "INV_Misc_Head_Tiger_01", "Tiger" },
    { "INV_Misc_Head_Dragon_Black", "Black dragon" }, { "INV_Misc_Head_Dragon_Red", "Red dragon" },
    { "INV_Misc_Head_Dragon_Green", "Green dragon" }, { "INV_Misc_Head_Dragon_Blue", "Blue dragon" },
}

-- "Female-Human" from a unit (UnitSex: 2 male, 3 female; older clients 0 male, 1 female)
local function lookOf(unit)
    if not UnitRace or not UnitSex then return "" end
    local _, file = UnitRace(unit)
    if not file then return "" end
    file = strgsub(file, " ", "")
    local ok = false
    for _, r in ipairs(RACES) do if r == file then ok = true end end
    if not ok then return "" end
    local s = UnitSex(unit)
    return ((s == 3 or s == 1) and "Female" or "Male") .. "-" .. file
end

validLook = function(s)
    if blank(s) then return false end
    local _, _, sex, race = strfind(s, "^(%a+)%-(%a+)$")
    if sex ~= "Female" and sex ~= "Male" then return false end
    for _, r in ipairs(RACES) do if r == race then return true end end
    return false
end

validPic = function(s)
    if blank(s) or s == "me" or s == "crest" then return true end
    local _, _, kind, val = strfind(s, "^(%a+):([%w_%-]+)$")
    if kind == "race" then return validLook(val) end
    if kind == "npc" then
        for _, f in ipairs(NPC_FACES) do if f[1] == val then return true end end
    end
    return false
end

-- a unit id that is this player right now, so the live portrait can be drawn
local function unitFor(name)
    if name == me() then return "player" end
    for _, u in ipairs({ "target", "mouseover", "party1", "party2", "party3", "party4" }) do
        if UnitExists and UnitExists(u) and UnitIsPlayer and UnitIsPlayer(u) and UnitName(u) == name then return u end
    end
end

-- SetPortraitToTexture by the texture's name (the browser engine takes the name, not the object);
-- falls back to a square SetTexture when neither works
local function roundPortrait(t, path)
    if SetPortraitToTexture and path then
        local n = t.GetName and t:GetName()
        if (n and pcall(SetPortraitToTexture, n, path)) or pcall(SetPortraitToTexture, t, path) then return true end
    end
    t:SetTexture(path)
end
-- paint p's picture on tex. round: tex is a round portrait slot (frame art masks the corners)
local function paintPicture(tex, p, name, round)
    local pic = (p and p.pic) or ""
    local function file(path, icon)
        if round and roundPortrait(tex, path) then tex:SetTexCoord(0, 1, 0, 1); return end
        tex:SetTexture(path)
        if icon then tex:SetTexCoord(0.07, 0.93, 0.07, 0.93) else tex:SetTexCoord(0.1, 0.9, 0.1, 0.9) end
    end
    if pic == "" or pic == "me" then
        local u = name and unitFor(name)
        if u and SetPortraitTexture then
            SetPortraitTexture(tex, u)
            tex:SetTexCoord(round and 0 or 0.1, round and 1 or 0.9, round and 0 or 0.1, round and 1 or 0.9)
            return
        end
        local look = (p and validLook(p.look) and p.look) or (name == me() and lookOf("player")) or ""
        if look ~= "" then return file(PORTRAIT_DIR .. look) end
        if p and not blank(p.crest) and pic == "" then
            if round and SetPortraitToTexture then return file("Interface\\Icons\\" .. p.crest, true) end
            return crestTexture(tex, p.crest)
        end
        return file(ICON_FALLBACK, true)
    end
    local _, _, kind, val = strfind(pic, "^(%a+):(.+)$")
    if kind == "race" then return file(PORTRAIT_DIR .. val) end
    if kind == "npc" then return file("Interface\\Icons\\" .. val, true) end
    -- "crest"
    if round and SetPortraitToTexture and p and not blank(p.crest) and p.crest ~= "Persona" then
        return file("Interface\\Icons\\" .. p.crest, true)
    end
    crestTexture(tex, p and p.crest)
end
P.PaintPicture = paintPicture

-- -- Window --------------------------------------------------------------------------------
-- The stock Character-frame look (UI.ClassicFrame): your picture in the round portrait, the
-- title on the strip, bottom tabs for My profile / Edit / Browse. Editing is four short steps
-- (Basics, Picture, Story, Extras) with Back and Next, each with a line saying what it's for.

local UI   -- WenillaCore's window kit, looked up when the window is first built (load order varies)
local win
local W_, H_ = 384, 512
local BW = W_ - 34          -- body width inside the frame

local STEPS = { { "who", "Basics" }, { "pic", "Picture" }, { "story", "Story" }, { "ooc", "Extras" } }
local STEP_HELP = {
    who = "Start with a name and how you're playing tonight. Every field is optional; save any time.",
    pic = "Choose the picture other players see on your profile and in Browse.",
    story = "What your character is up to, how they look, and their story so far.",
    ooc = "Small details, a few quotes or rumours, and out-of-character notes.",
}
local STATUS_LABEL = { ic = "In character", ooc = "Out of character", lfrp = "Looking for RP", st = "Storytelling" }
local STATUS_HELP = {
    ic = "You're playing your character: what you say and do is them.",
    ooc = "You're yourself right now. Others won't treat your chat as your character.",
    lfrp = "You'd like someone to start a scene with you. Walk-ups welcome.",
    st = "You're running a story or event others can join.",
}
local EXP_LABEL = { ["1"] = "New", ["2"] = "Casual", ["3"] = "Experienced", ["4"] = "Mentor" }
local EXP_HELP = {
    [""] = "Optional. New players get a friendly tag on their tooltip.",
    ["1"] = "New to roleplay: others will know to go easy and help out.",
    ["2"] = "You roleplay now and then.",
    ["3"] = "You roleplay a lot and know the ropes.",
    ["4"] = "You're happy to guide newcomers into a scene.",
}

local function text(parent, template, size)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    return fs
end

local function label(parent, txt, x, y, hint)
    local fs = text(parent, "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(txt)
    if hint then
        local h = text(parent, "GameFontDisableSmall")
        h:SetPoint("LEFT", fs, "RIGHT", 6, 0)
        h:SetText(hint)
        fs.hint = h
    end
    return fs
end

local function button(parent, txt, w, h)
    local b = (UI and UI.Button(parent, txt, w, h)) or CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    if not UI then b:SetWidth(w); b:SetHeight(h); b:SetText(txt) end
    return b
end

local function edit(parent, x, y, w, h, limit, multi)
    local box
    if multi then
        local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
        sf:SetWidth(w - 22)
        sf:SetHeight(h)
        local bg = CreateFrame("Frame", nil, parent)
        bg:SetPoint("TOPLEFT", sf, "TOPLEFT", -5, 5)
        bg:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", 26, -5)
        bg:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        bg:SetBackdropColor(0, 0, 0, 0.6)
        bg:SetBackdropBorderColor(0.75, 0.62, 0.35, 1)
        box = CreateFrame("EditBox", nil, sf)
        box:SetMultiLine(true)
        box:SetWidth(w - 26)
        box:SetHeight(h)
        box:SetFontObject(GameFontHighlightSmall)
        sf:SetScrollChild(box)
        box:SetScript("OnCursorChanged", function() ScrollingEdit_OnCursorChanged(arg1, arg2, arg3, arg4) end)
        box:SetScript("OnUpdate", function() ScrollingEdit_OnUpdate() end)
        box.scroll = sf
        box.bg = bg
    else
        box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
        box:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 6, y)
        box:SetWidth(w - 6)
        box:SetHeight(20)
    end
    box:SetAutoFocus(false)
    box:SetMaxLetters(limit)
    box:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    if not multi then
        box:SetScript("OnEnterPressed", function() this:ClearFocus() end)
        box:SetScript("OnTabPressed", function() if this.nextBox then this.nextBox:SetFocus() end end)
    end
    return box
end

-- a labelled one-line field; returns the box
local function field(parent, txt, x, y, w, limit, hint)
    label(parent, txt, x, y, hint)
    return edit(parent, x, y - 14, w, 20, limit)
end

local function setTab(buttons, which)
    for k, b in pairs(buttons) do
        if k == which then b:LockHighlight() else b:UnlockHighlight() end
    end
end

-- a 40x40 picture button with the slot border and a gold ring when chosen
local function picButton(parent, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(size); b:SetHeight(size)
    local slot = b:CreateTexture(nil, "BACKGROUND")
    slot:SetTexture("Interface\\Buttons\\UI-EmptySlot-Disabled")
    slot:SetWidth(size * 64 / 37); slot:SetHeight(size * 64 / 37)
    slot:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints(b)
    b.sel = b:CreateTexture(nil, "OVERLAY")
    b.sel:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    b.sel:SetBlendMode("ADD")
    b.sel:SetAllPoints(b)
    b.sel:Hide()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    return b
end

local function build()
    if win then return win end
    UI = WenillaCore and WenillaCore.UI
    local W, H = W_, H_
    if UI and UI.ClassicFrame then
        win = UI.ClassicFrame("PersonaFrame", { width = W, height = H, title = "Persona",
            portrait = ICON_FALLBACK, point = { "CENTER", UIParent, "CENTER", 0, 20 },
            tabs = { { key = "view", label = "My profile" }, { key = "edit", label = "Edit" }, { key = "list", label = "Browse" } },
            onTab = function(key)
                if key == "view" then P.ShowView(me()) elseif key == "edit" then P.ShowEdit() else P.ShowList() end
            end })
    else
        -- without WenillaCore: the stock dialog box with the same regions
        win = CreateFrame("Frame", "PersonaFrame", UIParent)
        win:SetWidth(W); win:SetHeight(H); win:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        win:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 } })
        win:EnableMouse(true); win:SetMovable(true)
        win:RegisterForDrag("LeftButton")
        win:SetScript("OnDragStart", function() this:StartMoving() end)
        win:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
        local c = CreateFrame("Button", nil, win, "UIPanelCloseButton")
        c:SetPoint("TOPRIGHT", win, "TOPRIGHT", -2, -2)
        win.title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        win.title:SetPoint("TOP", win, "TOP", 0, -14)
        win.portrait = win:CreateTexture(nil, "ARTWORK")
        win.portrait:SetWidth(44); win.portrait:SetHeight(44)
        win.portrait:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -12)
        win.toolbar = CreateFrame("Frame", nil, win)
        win.toolbar:SetPoint("TOPLEFT", win, "TOPLEFT", 66, -38)
        win.toolbar:SetPoint("TOPRIGHT", win, "TOPRIGHT", -14, -38)
        win.toolbar:SetHeight(28)
        win.body = CreateFrame("Frame", nil, win)
        win.body:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -76)
        win.body:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -14, 40)
        win.navButtons = {}
        local nx = 16
        for _, def in ipairs({ { "view", "My profile", 96 }, { "edit", "Edit", 64 }, { "list", "Browse", 72 } }) do
            local key = def[1]
            local b = button(win, def[2], def[3], 22)
            b:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", nx, 14)
            b:SetScript("OnClick", function()
                if key == "view" then P.ShowView(me()) elseif key == "edit" then P.ShowEdit() else P.ShowList() end
            end)
            win.navButtons[key] = b
            nx = nx + def[3] + 4
        end
    end
    win:SetFrameStrata("DIALOG")
    tinsert(UISpecialFrames, "PersonaFrame")   -- Escape closes it
    win:SetScript("OnHide", function() P.listShown = nil end)
    local body = win.body

    -- the header band beside the portrait: the step buttons while editing, the status otherwise
    local band = win.toolbar
    win.bandText = text(band, "GameFontNormal")
    win.bandText:SetPoint("LEFT", band, "LEFT", 4, 0)
    win.bandText:SetPoint("RIGHT", band, "RIGHT", -4, 0)

    -- Edit page ----------------------------------------------------------------
    local e = CreateFrame("Frame", nil, body)
    e:SetAllPoints(body)
    win.edit = e
    e.tabs, e.pages = {}, {}
    e.steps = CreateFrame("Frame", nil, band)
    e.steps:SetAllPoints(band)
    local sx = 2
    for i, def in ipairs(STEPS) do
        local key, n = def[1], i
        local b = button(e.steps, n .. ". " .. def[2], 68, 20)
        b:SetPoint("LEFT", e.steps, "LEFT", sx, 0)
        b:SetScript("OnClick", function() P.EditTab(key) end)
        e.tabs[key] = b
        sx = sx + 72
        local pg = CreateFrame("Frame", nil, e)
        pg:SetPoint("TOPLEFT", e, "TOPLEFT", 0, 0)
        pg:SetPoint("BOTTOMRIGHT", e, "BOTTOMRIGHT", 0, 34)
        local help = text(pg, "GameFontHighlightSmall")
        help:SetPoint("TOPLEFT", pg, "TOPLEFT", 4, -2)
        help:SetWidth(BW - 8)
        help:SetTextColor(0.9, 0.85, 0.7)
        help:SetText(STEP_HELP[key])
        pg.help = help
        e.pages[key] = pg
    end
    local half = (BW - 12) / 2

    -- 1. Basics
    local pg = e.pages.who
    e.name = field(pg, "Roleplay name", 4, -32, BW - 8, LIMITS.name, "blank = your character name")
    e.title = field(pg, "Title", 4, -74, BW - 8, LIMITS.title, "e.g. Knight of the Silver Hand")
    e.name.nextBox, e.title.nextBox = e.title, e.name
    label(pg, "Right now I'm", 4, -118)
    e.status = "ooc"
    e.statusButtons = {}
    for i, s in ipairs(STATUS_ORDER) do
        local key = s
        local b = button(pg, STATUS_LABEL[s], half, 22)
        local col, row = math.mod(i - 1, 2), math.floor((i - 1) / 2)
        b:SetPoint("TOPLEFT", pg, "TOPLEFT", 4 + col * (half + 4), -134 - row * 26)
        b:SetScript("OnClick", function() e.status = key; P.RefreshEditChoices() end)
        b:SetScript("OnEnter", function()
            GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
            GameTooltip:SetText(STATUS_LABEL[key], 1, 1, 1)
            GameTooltip:AddLine(STATUS_HELP[key], 0.9, 0.85, 0.7, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        e.statusButtons[key] = b
    end
    e.statusHelp = text(pg, "GameFontDisableSmall")
    e.statusHelp:SetPoint("TOPLEFT", pg, "TOPLEFT", 6, -190)
    e.statusHelp:SetWidth(BW - 12)
    label(pg, "Roleplay experience", 4, -216)
    e.expButtons = {}
    local ew = (BW - 8 - 12) / 4
    for i, k in ipairs({ "1", "2", "3", "4" }) do
        local key = k
        local b = button(pg, EXP_LABEL[k], ew, 22)
        b:SetPoint("TOPLEFT", pg, "TOPLEFT", 4 + (i - 1) * (ew + 4), -232)
        b:SetScript("OnClick", function() e.exp = (e.exp == key) and "" or key; P.RefreshEditChoices() end)
        e.expButtons[key] = b
    end
    e.expHelp = text(pg, "GameFontDisableSmall")
    e.expHelp:SetPoint("TOPLEFT", pg, "TOPLEFT", 6, -262)
    e.expHelp:SetWidth(BW - 12)

    -- 2. Picture
    pg = e.pages.pic
    e.picPreview = picButton(pg, 56)
    e.picPreview:SetPoint("TOPLEFT", pg, "TOPLEFT", 14, -34)
    e.picPreview:EnableMouse(false)
    e.picName = text(pg, "GameFontNormal")
    e.picName:SetPoint("TOPLEFT", e.picPreview, "TOPRIGHT", 16, -4)
    e.picName:SetWidth(BW - 100)
    local mine = button(pg, "Use my character", 130, 22)
    mine:SetPoint("TOPLEFT", e.picName, "BOTTOMLEFT", -2, -8)
    mine:SetScript("OnClick", function() e.pic = "me"; P.RefreshEditChoices() end)
    e.picGroups = {}
    e.picGroup = "faces"
    local gx = 4
    for _, def in ipairs({ { "faces", "Faces" }, { "npcs", "Heroes & creatures" }, { "crests", "Emblems" } }) do
        local key = def[1]
        local w = (key == "npcs") and 136 or 80
        local b = button(pg, def[2], w, 22)
        b:SetPoint("TOPLEFT", pg, "TOPLEFT", gx, -104)
        b:SetScript("OnClick", function() e.picGroup = key; P.RefreshEditChoices() end)
        e.picGroups[key] = b
        gx = gx + w + 4
    end
    e.picGrid = {}
    local COLS, SIZE, GAP = 7, 38, 10
    for i = 1, 28 do
        local b = picButton(pg, SIZE)
        local col, row = math.mod(i - 1, COLS), math.floor((i - 1) / COLS)
        b:SetPoint("TOPLEFT", pg, "TOPLEFT", 10 + col * (SIZE + GAP), -140 - row * (SIZE + GAP))
        b:SetScript("OnClick", function()
            if this.crest then e.pic = "crest"; e.crest = this.crest else e.pic = this.pic end
            P.RefreshEditChoices()
        end)
        b:SetScript("OnEnter", function()
            if not this.tip then return end
            GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
            GameTooltip:SetText(this.tip, 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        e.picGrid[i] = b
    end
    e.crestButtons = {}

    -- 3. Story
    pg = e.pages.story
    e.currently = field(pg, "Currently", 4, -32, BW - 8, LIMITS.currently, "what your character is doing now")
    label(pg, "Appearance", 4, -76, "what others notice at a glance")
    e.appearance = edit(pg, 10, -94, BW - 14, 70, LIMITS.appearance, true)
    label(pg, "Story", 4, -178, "their history, in your words")
    e.bio = edit(pg, 10, -196, BW - 14, 170, LIMITS.bio, true)

    -- 4. Extras
    pg = e.pages.ooc
    e.pronouns = field(pg, "Pronouns", 4, -32, half, LIMITS.pronouns)
    e.age = field(pg, "Age", 12 + half, -32, half, LIMITS.age)
    e.build = field(pg, "Height & build", 4, -74, half, LIMITS.build)
    e.home = field(pg, "Home", 12 + half, -74, half, LIMITS.home)
    e.motto = field(pg, "Motto or saying", 4, -116, BW - 8, LIMITS.motto)
    e.pronouns.nextBox, e.age.nextBox, e.build.nextBox = e.age, e.build, e.home
    e.home.nextBox, e.motto.nextBox = e.motto, e.pronouns
    label(pg, "Quotes & rumours", 4, -160, "one per line, up to five")
    e.shares = edit(pg, 10, -178, BW - 14, 64, LIMITS.share * 5, true)
    e.occur = field(pg, "Out of character", 4, -254, BW - 8, LIMITS.occur, "e.g. Back in 10")
    e.author = field(pg, "Player note", 4, -296, BW - 8, LIMITS.author, "on all your characters")
    local hint = text(pg, "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", pg, "TOPLEFT", 6, -340)
    hint:SetWidth(BW - 12)
    hint:SetText("Your Persona is shared with players on this realm. Players you ignore never see it, and you never see theirs.")

    -- Back / Next / Save
    e.back = button(e, "< Back", 70, 22)
    e.back:SetPoint("BOTTOMLEFT", e, "BOTTOMLEFT", 2, 4)
    e.back:SetScript("OnClick", function() P.EditStep(-1) end)
    e.next = button(e, "Next >", 70, 22)
    e.next:SetPoint("LEFT", e.back, "RIGHT", 4, 0)
    e.next:SetScript("OnClick", function() P.EditStep(1) end)
    local save = button(e, "Save & share", 110, 22)
    save:SetPoint("BOTTOMRIGHT", e, "BOTTOMRIGHT", -2, 4)
    save:SetScript("OnClick", function() P.Save() end)
    e.count = text(e, "GameFontDisableSmall")
    e.count:SetPoint("RIGHT", save, "LEFT", -8, 0)

    -- View page ------------------------------------------------------------------
    local v = CreateFrame("Frame", nil, body)
    v:SetAllPoints(body)
    win.view = v
    local page = v:CreateTexture(nil, "BACKGROUND")
    page:SetPoint("TOPLEFT", v, "TOPLEFT", 0, 0)
    page:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", 0, 34)
    v.parchment = art(page, "Parchment", nil)
    if not v.parchment then page:SetTexture(0.10, 0.08, 0.06, 0.75) end
    v.page = page

    v.head = text(v, "GameFontNormalLarge")
    v.head:SetPoint("TOPLEFT", v, "TOPLEFT", 14, -12)
    v.head:SetPoint("RIGHT", v, "RIGHT", -14, 0)
    -- the Live badge (generated art, Persona_Live) when they are streaming now (Social/Live.lua)
    v.live = v:CreateTexture(nil, "OVERLAY")
    v.live:SetWidth(64); v.live:SetHeight(32)
    v.live:SetPoint("TOPRIGHT", v, "TOPRIGHT", -10, -6)
    v.liveArt = art(v.live, "Persona_LiveBadge", nil)
    v.liveText = text(v, "GameFontNormalSmall")
    v.liveText:SetPoint("CENTER", v.live, "CENTER", 0, 0)
    v.live:Hide(); v.liveText:Hide()
    v.sub = text(v, "GameFontHighlightSmall")
    v.sub:SetPoint("TOPLEFT", v.head, "BOTTOMLEFT", 0, -4)
    v.sub:SetPoint("RIGHT", v, "RIGHT", -14, 0)
    v.glance = text(v, "GameFontHighlightSmall")
    v.glance:SetPoint("TOPLEFT", v.sub, "BOTTOMLEFT", 0, -3)
    v.glance:SetPoint("RIGHT", v, "RIGHT", -14, 0)
    if v.parchment then
        v.head:SetTextColor(0.32, 0.14, 0.42)
        v.sub:SetTextColor(0.22, 0.14, 0.08)
        v.glance:SetTextColor(0.36, 0.26, 0.18)
    end
    local div = v:CreateTexture(nil, "ARTWORK")
    div:SetWidth(256); div:SetHeight(24)
    div:SetPoint("TOP", v, "TOP", 0, -62)
    if not art(div, "Persona_Divider", nil) then
        div:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Divider")
        div:SetTexCoord(0, 1, 0, 1)
    end

    local sf = CreateFrame("ScrollFrame", "PersonaViewScroll", v, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", v, "TOPLEFT", 14, -88)
    sf:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", -30, 42)
    local sbody = CreateFrame("Frame", nil, sf)
    sbody:SetWidth(BW - 46); sbody:SetHeight(10)
    sf:SetScrollChild(sbody)
    v.text = text(sbody, "GameFontHighlightSmall")
    v.text:SetPoint("TOPLEFT", sbody, "TOPLEFT", 0, 0)
    v.text:SetWidth(BW - 46)
    v.body = sbody
    v.scroll = sf

    v.whisper = button(v, "Whisper", 80, 22)
    v.whisper:SetPoint("BOTTOMLEFT", v, "BOTTOMLEFT", 2, 4)
    v.whisper:SetScript("OnClick", function()
        if P.viewing and ChatFrame_OpenChat then ChatFrame_OpenChat("/w " .. P.viewing .. " ") end
    end)
    v.again = button(v, "Refresh", 80, 22)
    v.again:SetPoint("LEFT", v.whisper, "RIGHT", 4, 0)
    v.again:SetScript("OnClick", function()
        if P.viewing then asked[P.viewing] = nil; P.Request(P.viewing); P.ShowView(P.viewing) end
    end)
    v.report = button(v, "Report", 64, 22)
    v.report:SetPoint("LEFT", v.again, "RIGHT", 4, 0)
    v.report:SetScript("OnClick", function()
        if P.viewing and WenillaCore.Report then WenillaCore.Report.Open(P.viewing, "persona") end
    end)
    v.editMine = button(v, "Edit my profile", 120, 22)
    v.editMine:SetPoint("BOTTOMLEFT", v, "BOTTOMLEFT", 2, 4)
    v.editMine:SetScript("OnClick", function() P.ShowEdit() end)
    v.seen = text(v, "GameFontDisableSmall")
    v.seen:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", -4, 10)

    -- Browse page ----------------------------------------------------------------
    local l = CreateFrame("Frame", nil, body)
    l:SetAllPoints(body)
    win.list = l
    l.search = edit(l, 0, -2, 170, 20, 40)
    l.searchHint = text(l, "GameFontDisableSmall")
    l.searchHint:SetPoint("LEFT", l.search, "LEFT", 2, 0)
    l.searchHint:SetText("Search names, titles, homes")
    l.search:SetScript("OnTextChanged", function()
        if (this:GetText() or "") == "" then l.searchHint:Show() else l.searchHint:Hide() end
        l.page = 1; P.RefreshList()
    end)
    l.search:SetScript("OnEditFocusGained", function() l.searchHint:Hide() end)
    l.search:SetScript("OnEditFocusLost", function() if (this:GetText() or "") == "" then l.searchHint:Show() end end)
    l.filter = "all"
    l.filters = {}
    local fx = 0
    for _, def in ipairs({ { "all", "Everyone", 74 }, { "lfrp", "Looking for RP", 108 }, { "today", "Seen today", 86 } }) do
        local key = def[1]
        local b = button(l, def[2], def[3], 20)
        b:SetPoint("TOPLEFT", l, "TOPLEFT", fx, -28)
        b:SetScript("OnClick", function() l.filter = key; l.page = 1; P.RefreshList() end)
        l.filters[key] = b
        fx = fx + def[3] + 4
    end
    l.rows = {}
    for i = 1, 8 do
        local r = CreateFrame("Button", nil, l)
        r:SetHeight(38)
        r:SetPoint("TOPLEFT", l, "TOPLEFT", 0, -56 - (i - 1) * 40)
        r:SetPoint("RIGHT", l, "RIGHT", 0, 0)
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        local bg = r:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(r)
        bg:SetTexture(0, 0, 0, math.mod(i, 2) == 0 and 0.25 or 0.12)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetWidth(32); r.icon:SetHeight(32)
        r.icon:SetPoint("LEFT", r, "LEFT", 4, 0)
        r.gem = r:CreateTexture(nil, "OVERLAY")
        r.gem:SetWidth(12); r.gem:SetHeight(12)
        r.gem:SetPoint("BOTTOMRIGHT", r.icon, "BOTTOMRIGHT", 3, -3)
        r.name = text(r, "GameFontNormal")
        r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, -1)
        r.name:SetPoint("RIGHT", r, "RIGHT", -70, 0)
        r.title = text(r, "GameFontHighlightSmall")
        r.title:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 8, 1)
        r.title:SetPoint("RIGHT", r, "RIGHT", -70, 0)
        r.seen = text(r, "GameFontDisableSmall")
        r.seen:SetPoint("RIGHT", r, "RIGHT", -6, 0)
        r:SetScript("OnClick", function() if this.who then P.ShowView(this.who) end end)
        l.rows[i] = r
    end
    l.page = 1
    l.prev = button(l, "<", 28, 22)
    l.prev:SetPoint("BOTTOMLEFT", l, "BOTTOMLEFT", 2, 4)
    l.prev:SetScript("OnClick", function() l.page = math.max(1, l.page - 1); P.RefreshList() end)
    l.next = button(l, ">", 28, 22)
    l.next:SetPoint("LEFT", l.prev, "RIGHT", 4, 0)
    l.next:SetScript("OnClick", function() l.page = l.page + 1; P.RefreshList() end)
    l.info = text(l, "GameFontDisableSmall")
    l.info:SetPoint("LEFT", l.next, "RIGHT", 10, 0)
    l.empty = text(l, "GameFontDisable")
    l.empty:SetPoint("CENTER", l, "CENTER", 0, 20)
    l.empty:SetWidth(BW - 60)
    l.empty:SetJustifyH("CENTER")
    l.empty:SetText("No profiles yet. Mouse over or target other players and their Personas collect here.")

    win:Hide()
    return win
end

-- the portrait in the frame's round slot, and the band beside it
local function framePicture(p, name)
    if win.portrait then paintPicture(win.portrait, p, name, true) end
end

local function showPage(which)
    win.edit:Hide(); win.view:Hide(); win.list:Hide()
    win[which]:Show()
    P.listShown = (which == "list") or nil
    if which == "edit" then win.edit.steps:Show(); win.bandText:Hide() else win.edit.steps:Hide(); win.bandText:Show() end
    local nav = (which == "view" and P.viewing ~= me()) and "none" or which
    if win.tabs then
        win.tabs.selected = nil
        if nav ~= "none" then win.tabs:Select(nav, true) else win.tabs:Select("__none", true) end
    elseif win.navButtons then
        setTab(win.navButtons, nav)
    end
    win:Show()
end

function P.EditTab(key)
    local e = win.edit
    for k, pg in pairs(e.pages) do if k == key then pg:Show() else pg:Hide() end end
    setTab(e.tabs, key)
    e.tab = key
    local idx = 1
    for i, s in ipairs(STEPS) do if s[1] == key then idx = i end end
    if idx > 1 then e.back:Enable() else e.back:Disable() end
    if idx < getn(STEPS) then e.next:Show() else e.next:Hide() end
end

function P.EditStep(d)
    local e = win.edit
    local idx = 1
    for i, s in ipairs(STEPS) do if s[1] == (e.tab or "who") then idx = i end end
    idx = math.max(1, math.min(getn(STEPS), idx + d))
    P.EditTab(STEPS[idx][1])
end

local function picLabel(e)
    local pic = e.pic or ""
    if pic == "" or pic == "me" then return "Your character" end
    if pic == "crest" then return "Emblem" end
    local _, _, kind, val = strfind(pic, "^(%a+):(.+)$")
    if kind == "race" then
        local _, _, sex, race = strfind(val, "^(%a+)%-(%a+)$")
        return (RACE_NAMES[race] or race) .. ", " .. strlower(sex or "")
    end
    for _, f in ipairs(NPC_FACES) do if f[1] == val then return f[2] end end
    return ""
end

function P.RefreshEditChoices()
    local e = win.edit
    setTab(e.statusButtons, e.status)
    e.statusHelp:SetText(STATUS_HELP[e.status] or "")
    setTab(e.expButtons, e.exp or "")
    e.expHelp:SetText(EXP_HELP[e.exp or ""] or EXP_HELP[""])
    -- picture
    local draft = { pic = e.pic or "", crest = e.crest or "", look = lookOf("player") }
    paintPicture(e.picPreview.icon, draft, me(), false)
    framePicture(draft, me())
    e.picName:SetText(picLabel(e))
    setTab(e.picGroups, e.picGroup)
    local items = {}
    if e.picGroup == "faces" then
        for _, sex in ipairs({ "Male", "Female" }) do
            for _, r in ipairs(RACES) do
                tinsert(items, { pic = "race:" .. sex .. "-" .. r, tip = RACE_NAMES[r] .. ", " .. strlower(sex),
                    path = PORTRAIT_DIR .. sex .. "-" .. r })
            end
        end
    elseif e.picGroup == "npcs" then
        for _, f in ipairs(NPC_FACES) do tinsert(items, { pic = "npc:" .. f[1], tip = f[2], path = "Interface\\Icons\\" .. f[1], icon = true }) end
    else
        for _, c in ipairs(CRESTS) do tinsert(items, { crest = c, tip = "Emblem" }) end
    end
    for k in pairs(e.crestButtons) do e.crestButtons[k] = nil end
    for i, b in ipairs(e.picGrid) do
        local it = items[i]
        if it then
            b.pic, b.crest, b.tip = it.pic, it.crest, it.tip
            if it.crest then
                crestTexture(b.icon, it.crest)
                e.crestButtons[it.crest] = b
            else
                b.icon:SetTexture(it.path)
                if it.icon then b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) else b.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9) end
            end
            local on = (it.pic and it.pic == e.pic) or (it.crest and e.pic == "crest" and (e.crest == it.crest
                or (blank(e.crest) and it.crest == "Persona")))
            if on then b.sel:Show() else b.sel:Hide() end
            b:Show()
        else
            b.pic, b.crest, b.tip = nil, nil, nil
            b:Hide()
        end
    end
end

local function tick()
    if not win or not win.edit:IsShown() then return end
    local e = win.edit
    e.count:SetText(strlen(e.bio:GetText() or "") .. " / " .. LIMITS.bio)
end

function P.ShowEdit()
    build()
    local p = P.Mine()
    local e = win.edit
    for _, k in ipairs({ "name", "title", "pronouns", "age", "build", "home", "motto", "currently", "occur", "appearance", "bio" }) do
        e[k]:SetText(p[k] or "")
    end
    local shares = {}
    for i = 1, 5 do if not blank(p["s" .. i]) then tinsert(shares, p["s" .. i]) end end
    e.shares:SetText(table.concat(shares, "\n"))
    e.author:SetText(db().author or "")
    e.status = p.status or "ooc"
    e.exp = p.exp or ""
    e.crest = p.crest or ""
    e.pic = p.pic or ""
    if e.pic == "" and not blank(e.crest) then e.pic = "crest" end
    P.RefreshEditChoices()
    P.EditTab(e.tab or "who")
    if win.title then win.title:SetText("Persona: edit your profile") end
    P.viewing = nil
    showPage("edit")
    tick()
end

function P.Save()
    local e = win.edit
    local p = P.Mine()
    for _, k in ipairs({ "name", "title", "pronouns", "age", "build", "home", "motto", "currently", "occur", "appearance", "bio" }) do
        p[k] = clip(e[k]:GetText(), LIMITS[k])
    end
    local i = 1
    for line in string.gfind((e.shares:GetText() or "") .. "\n", "([^\n]*)\n") do
        if line ~= "" and i <= 5 then p["s" .. i] = clip(line, LIMITS.share); i = i + 1 end
    end
    for k = i, 5 do p["s" .. k] = nil end
    db().author = clip(e.author:GetText(), LIMITS.author)
    p.author = db().author
    p.status = e.status or "ooc"
    p.exp = e.exp or ""
    p.crest = e.crest or ""
    p.pic = validPic(e.pic) and (e.pic or "") or ""
    p.look = lookOf("player")
    p.rev = (p.rev or 0) + 1
    lastFull = -100
    announce()
    refreshMinimap(); refreshBadge()
    Print("saved. Players who mouse over or target you will see it.")
    P.ShowView(me())
end

local function para(head, body)
    if blank(body) then return "" end
    return "|cff7a4fa0" .. head .. "|r\n" .. body .. "\n\n"
end

local function ago(t)
    if not t or t == 0 then return "" end
    local d = now() - t
    if d < 60 then return "just now" end
    if d < 3600 then return math.floor(d / 60) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    return math.floor(d / 86400) .. "d ago"
end

function P.ShowView(name)
    build()
    P.viewing = name
    local p = P.Get(name)
    local v = win.view
    if win.title then win.title:SetText(name == me() and "Persona: your profile" or ("Persona: " .. name)) end
    framePicture(p, name)
    -- dark ink on parchment, light text on the plain dark fallback
    local ink = v.parchment and "|cff2a1a10" or "|cffe8e0d0"
    local s = p and STATUS_TEXT[p.status or ""] and p.status or "ooc"
    win.bandText:SetText(p and (STATUS_TEXT[s] or "") or "")
    if not p or p.rev == -1 then
        v.head:SetText(clean(P.DisplayName(p, name)))
        v.sub:SetText(p and clean(p.title) or "")
        v.glance:SetText("")
        v.text:SetText(ink .. "Asking " .. name .. " for their Persona...\n\nThey need to be online. "
            .. "Every Classic+ player has Persona; players on other clients may not.|r")
        v.seen:SetText("")
        P.Request(name)
    else
        local shown = P.DisplayName(p, name)
        v.head:SetText(clean(shown) .. ((shown ~= name) and ("  |cff6a5a4a(" .. name .. ")|r") or ""))
        local st = (v.parchment and STATUS_INK or STATUS_TEXT)[p.status or ""] or ""
        v.sub:SetText((not blank(p.title) and ("<" .. clean(p.title) .. ">   ") or "") .. st)
        v.glance:SetText(glance(p))
        local shares = ""
        for i = 1, 5 do if not blank(p["s" .. i]) then shares = shares .. "|cff7a4fa0\226\128\162|r " .. clean(p["s" .. i]) .. "\n" end end
        local motto = blank(p.motto) and "" or ("|cff6a5040\"" .. clean(p.motto) .. "\"|r\n\n")
        local ooc = ""
        if not blank(p.occur) then ooc = ooc .. "Currently: " .. clean(p.occur) .. "\n" end
        if P.Listening(p) ~= "" then ooc = ooc .. "Listening to: " .. clean(P.Listening(p)) .. "\n" end
        if not blank(p.exp) and EXP_TEXT[p.exp] then ooc = ooc .. EXP_TEXT[p.exp] .. "\n" end
        if not blank(p.author) then ooc = ooc .. clean(p.author) .. "\n" end
        local body = motto .. para("Currently", clean(p.currently)) .. para("Appearance", clean(p.appearance))
            .. para("Story", clean(p.bio)) .. para("Quotes & rumours", shares) .. para("Player (out of character)", ooc)
        if body == "" then
            body = (name == me()) and "Nothing written yet. Press Edit my profile to write your Persona: it takes a minute."
                or (name .. " hasn't written anything yet.")
        end
        v.text:SetText(ink .. body .. "|r")
        v.seen:SetText(name == me() and ("version " .. (p.rev or 0)) or ("updated " .. ago(p.seen)))
        if p.stale and name ~= me() then P.Request(name) end
    end
    v.body:SetHeight((v.text:GetHeight() or 10) + 10)
    if v.scroll.UpdateScrollChildRect then v.scroll:UpdateScrollChildRect() end
    if Social and Social.IsLive and Social:IsLive(name) then
        v.live:Show()
        -- no art: the words on a red plate
        if not v.liveArt then v.live:SetTexture(0.75, 0.1, 0.08, 0.85); v.liveText:SetText("|cffffffffLIVE|r"); v.liveText:Show() end
    else
        v.live:Hide(); v.liveText:Hide()
    end
    if name == me() then v.whisper:Hide(); v.again:Hide(); v.report:Hide(); v.editMine:Show()
    else v.whisper:Show(); v.again:Show(); v.report:Show(); v.editMine:Hide() end
    showPage("view")
end

-- The LIVE list changed (Social/Live.lua): the target badge and an open profile follow.
function P.RefreshLive()
    refreshBadge()
    if win and win:IsShown() and win.view:IsShown() and P.viewing then P.ShowView(P.viewing) end
end

-- -- Browse --------------------------------------------------------------------------------

function P.RefreshList()
    if not win or not win.list.rows then return end
    local l = win.list
    local q = strlower(l.search:GetText() or "")
    local t = now()
    local items = {}
    local function consider(name, p)
        if not p or ignored(name) then return end
        if l.filter == "lfrp" and p.status ~= "lfrp" and p.status ~= "st" then return end
        if l.filter == "today" and t - (p.seen or 0) > 86400 then return end
        if q ~= "" then
            local hay = strlower(name .. " " .. (p.name or "") .. " " .. (p.title or "") .. " " .. (p.home or ""))
            if not strfind(hay, q, 1, true) then return end
        end
        tinsert(items, { name, p })
    end
    for name, p in pairs(db().cache[realm()]) do consider(name, p) end
    for name, p in pairs(demo) do if not db().cache[realm()][name] then consider(name, p) end end
    table.sort(items, function(a, b)
        local la = (a[2].status == "lfrp" or a[2].status == "st") and 1 or 0
        local lb = (b[2].status == "lfrp" or b[2].status == "st") and 1 or 0
        if la ~= lb then return la > lb end
        return (a[2].seen or 0) > (b[2].seen or 0)
    end)
    local per = getn(l.rows)
    local pages = math.max(1, math.ceil(getn(items) / per))
    if l.page > pages then l.page = pages end
    for i, r in ipairs(l.rows) do
        local it = items[(l.page - 1) * per + i]
        if it then
            local name, p = it[1], it[2]
            r.who = name
            paintPicture(r.icon, p, name, false)
            local s = STATUS_TEXT[p.status or ""] and p.status or "ooc"
            if not art(r.gem, STATUS_ART[s], nil) then local c = STATUS_RGB[s]; r.gem:SetTexture(c[1], c[2], c[3], 1) end
            local shown = P.DisplayName(p, name)
            r.name:SetText(clean(shown) .. ((shown ~= name) and (" |cff808080(" .. name .. ")|r") or ""))
            r.title:SetText(blank(p.title) and (p.rev == -1 and "|cff808080profile not read yet|r" or "") or ("<" .. clean(p.title) .. ">"))
            r.seen:SetText(ago(p.seen))
            r:Show()
        else
            r.who = nil
            r:Hide()
        end
    end
    l.info:SetText(getn(items) .. " profiles  " .. DOT .. "  page " .. l.page .. "/" .. pages)
    if getn(items) == 0 then l.empty:Show() else l.empty:Hide() end
    setTab(l.filters, l.filter)
end

function P.ShowList()
    build()
    if win.title then win.title:SetText("Persona: browse profiles") end
    framePicture(P.Mine(), me())
    win.bandText:SetText("Profiles you've come across on this realm")
    P.viewing = nil
    showPage("list")
    P.RefreshList()
end

function P.Toggle()
    if win and win:IsShown() then win:Hide() return end
    if UnitIsPlayer and UnitIsPlayer("target") and UnitName("target") ~= me() then
        return P.ShowView(UnitName("target"))
    end
    local p = P.Mine()
    if blank(p.name) and blank(p.title) and blank(p.bio) and blank(p.currently) then return P.ShowEdit() end
    P.ShowView(me())
end

function P.ToggleMine()
    if win and win:IsShown() and (P.viewing == me() or win.edit:IsShown()) then win:Hide() return end
    local p = P.Mine()
    if blank(p.name) and blank(p.title) and blank(p.bio) and blank(p.currently) then return P.ShowEdit() end
    P.ShowView(me())
end

-- -- Status --------------------------------------------------------------------------------

function P.SetStatus(s)
    if not STATUS_TEXT[s] then return end
    local p = P.Mine()
    p.status = s
    p.rev = (p.rev or 0) + 1
    lastFull = -100
    announce()
    refreshMinimap(); refreshBadge()
    if win and win:IsShown() and win.edit:IsShown() then win.edit.status = s; P.RefreshEditChoices() end
    Print("status: " .. STATUS_TEXT[s])
end

-- -- Demo profiles (Classic+ "/wnl demo": every window shows sample data) -----------------

local DEMO = {
    { "Ilyndra", "lfrp", "Ilyndra Vael'shan", "Keeper of the Moonwell Archive", "she/her", "Looks 30 (is 412)",
      "Tall, willowy", "Darnassus", "The stars remember what we forget.", "3", "Spell_Nature_StarFall",
      "Cataloguing star charts at the Lion's Pride Inn; happy to be interrupted.",
      "Silver hair braided with blue thread; ink on her fingers; a satchel of rolled star charts.",
      "Ilyndra left the Temple of the Moon after a vision she still won't describe. She travels the eastern kingdoms copying every star chart she finds, convinced one of them shows the night sky before the Sundering.",
      "Has been asking about an astrolabe stolen from a Goldshire farmhouse.", "race:Female-NightElf" },
    { "Brakkus", "ic", "Brakkus Ironjaw", "Sergeant of the Grommash Watch", "he/him", "41",
      "Broad, scarred", "Orgrimmar", "Strength and honour.", "2", "Ability_Warrior_BattleShout",
      "Drilling recruits outside the Valley of Honor.", "A notched axe across his back and one tusk capped in iron.",
      "A veteran of the internment camps who now trains the young ones to fight for something better.", "", "race:Male-Orc" },
    { "Thessaly", "st", "Thessaly Wren", "Bard of the Silver Road", "she/they", "27", "Small, quick",
      "Lakeshire", "Every road is a story.", "4", "INV_Misc_Note_01",
      "Running a tavern tale night at the Scarlet Raven: walk-ups welcome.", "A lute with a cracked neck, mended with gold leaf.",
      "Collects songs from every town she passes and swaps them for supper.", "Knows the real reason the Lakeshire bridge keeps falling.", "npc:INV_Misc_Head_Human_02" },
    { "Orlen", "ooc", "", "Apprentice cartographer", "he/him", "19", "Lanky", "Ironforge", "", "1", "INV_Misc_Map_01",
      "", "Ink-stained gloves, a too-large coat.", "New to the trade and to roleplay; say hi.", "", "race:Male-Dwarf" },
}

local function loadDemo(on)
    demo = {}
    if not on then return end
    for i, d in ipairs(DEMO) do
        demo[d[1]] = { status = d[2], name = d[3], title = d[4], pronouns = d[5], age = d[6], build = d[7],
            home = d[8], motto = d[9], exp = d[10], crest = d[11], currently = d[12], appearance = d[13],
            bio = d[14], s1 = (d[15] ~= "" and d[15]) or nil, pic = d[16], rev = 1, seen = now() - (i * 7 * 60) }
    end
end

-- -- Slash commands -------------------------------------------------------------------------

SLASH_PERSONA1, SLASH_PERSONA2 = "/persona", "/rp"
SlashCmdList["PERSONA"] = function(msg)
    msg = msg or ""
    local low = strlower(msg)
    if not active() then Print("is switched off. Turn it on in /addons.") return end
    if STATUS_TEXT[low] then return P.SetStatus(low) end
    if low == "edit" then return P.ShowEdit() end
    if low == "list" or low == "dir" or low == "directory" then return P.ShowList() end
    if low == "demo" then loadDemo(not next(demo)); Print(next(demo) and "sample profiles on (Directory)." or "sample profiles off.") return end
    if low == "help" then
        Print("/rp  your target's Persona or your own   " .. DOT .. "  /rp <name>   " .. DOT .. "  /rp edit   " .. DOT .. "  /rp list")
        Print("/rp ic | ooc | lfrp | st  set your status   " .. DOT .. "  /rp demo  sample profiles")
        return
    end
    if msg ~= "" then
        local name = strupper(strsub(msg, 1, 1)) .. strlower(strsub(msg, 2))
        return P.ShowView(name)
    end
    P.Toggle()
end

-- Right-click menu on player units: "View Persona".
if UnitPopupButtons and UnitPopupMenus then
    UnitPopupButtons["PERSONA_VIEW"] = { text = "View Persona", dist = 0 }
    for _, menu in ipairs({ "PLAYER", "PARTY", "RAID", "FRIEND", "SELF" }) do
        local m = UnitPopupMenus[menu]
        if m then tinsert(m, getn(m), "PERSONA_VIEW") end   -- just above "Cancel"
    end
    local orig = UnitPopup_OnClick
    UnitPopup_OnClick = function()
        if this and this.value == "PERSONA_VIEW" then
            local dd = getglobal(UIDROPDOWNMENU_INIT_MENU)
            local name = (dd and dd.name) or (dd and dd.unit and UnitName(dd.unit))
            if name then P.ShowView(name) end
            return
        end
        return orig()
    end
end

-- -- Events ---------------------------------------------------------------------------------

local function refreshAll()
    refreshMinimap(); refreshBadge()
    if not active() and win then win:Hide() end
end

local f = CreateFrame("Frame", "PersonaEventFrame")
f:RegisterEvent("VARIABLES_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("CHAT_MSG_CHANNEL")
f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
local joinWait, housekeeping, suiteDemo = nil, 0, false
f:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        db(); prune()
        readNowPlayingShim()
        local w = W()
        if w and w.RegisterAddon then w:RegisterAddon("Persona", function() refreshAll() end) end
        refreshAll()
    elseif event == "PLAYER_ENTERING_WORLD" then
        joinWait = 4   -- give the stock channels (General, Trade...) their slots first
        refreshAll()
    elseif event == "CHAT_MSG_CHANNEL" then
        -- arg9 is the channel's base name in 1.12 (arg4 is "N. Name").
        local base = arg9 or arg4 or ""
        if strfind(strlower(base), strlower(PERSONA_CHANNEL), 1, true) then onChannel(arg1, arg2) end
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        tipFor = nil
        decorateTooltip()
        if Social and Social.LiveTooltip then Social.LiveTooltip() end
    elseif event == "PLAYER_TARGET_CHANGED" then
        if UnitIsPlayer and UnitIsPlayer("target") then
            local n = UnitName("target")
            local p = P.Get(n)
            if not p or p.stale then P.Request(n) end
        end
        refreshBadge()
    end
end)
f:SetScript("OnUpdate", function()
    if joinWait then
        joinWait = joinWait - arg1
        if joinWait <= 0 then
            joinWait = nil
            joinOpen = true
            if active() then join(); announce() end
        end
    end
    flush(arg1)
    housekeeping = housekeeping + arg1
    if housekeeping > 1 then
        housekeeping = 0
        expireInbox()
        tick()
        if listenUntil and now() > listenUntil then listenUntil = nil; P.SetListening("") end
        local w = W()
        local want = (w and w.demoRunning) and true or false
        if want ~= suiteDemo then   -- follow the suite's demo switch when it changes
            suiteDemo = want
            loadDemo(want)
            if P.listShown then P.RefreshList() end
        end
    end
end)
