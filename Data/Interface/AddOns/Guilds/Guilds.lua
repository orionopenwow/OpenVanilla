--[[
    Guilds.lua  -  Concord
    The Guild Finder: guilds list themselves with a focus, a minimum level and a short pitch;
    anyone can browse, filter (focus tabs, search) and apply with one click (the application
    is a whisper to the officer who posted the listing). The window is the stock Character /
    Friends frame (UI.ClassicFrame) like Social; the crests are Guilds_* art with stock icons
    as the fallback (tools/gen_guilds_art.py).

    Listings travel over a hidden chat channel that every Classic+ client joins, so the board
    works on any realm today; a server registry ("CO" packets) feeds the same board.
    The channel never shows in chat windows.
        CO1~L~<guild>~<focus>~<minLevel>~<members>~<pitch>    a listing (re-sent every 10 min)
        CO1~Q                                                 "who is recruiting?"
    CO packet (server): same "L~..." body, or "announcement,<text>".
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Guilds"
local CHANNEL = "CPConcord"
local TTL = 25 * 60

Concord = Concord or {}
local G = Concord
G.listings = {}     -- guild -> listing
G.filter = 1
G.scroll = 0

local FOCUS = { "Any", "Raiding", "Leveling", "PvP", "Social", "Casual" }
local FOCUS_ICON = {
    Raiding = "Interface\\Icons\\Ability_Warrior_BattleShout",
    Leveling = "Interface\\Icons\\INV_Misc_Book_09",
    PvP = "Interface\\Icons\\Ability_DualWield",
    Social = "Interface\\Icons\\INV_Misc_Note_02",
    Casual = "Interface\\Icons\\INV_Misc_PocketWatch_01",
}

local strfind, strsub, strgsub = string.find, string.sub, string.gsub

local function clean(s)
    s = strgsub(s or "", "[~|]", "-")
    return W.Trim(s)
end

local function myPost()
    local c = WenillaCore_Config
    if not c then return nil end
    c.concord = c.concord or {}
    return c.concord[(UnitName("player") or "?")]
end

-- -- Channel -------------------------------------------------------------------

local function channelId()
    local id = GetChannelName and GetChannelName(CHANNEL)
    if id and id > 0 then return id end
end

local function joinChannel()
    if channelId() or not JoinChannelByName then return end
    JoinChannelByName(CHANNEL)
    for i = 1, (NUM_CHAT_WINDOWS or 7) do
        local cf = getglobal("ChatFrame" .. i)
        if cf and ChatFrame_RemoveChannel then pcall(ChatFrame_RemoveChannel, cf, CHANNEL) end
    end
end

local lastSend = 0
local function sendChannel(msg, force)
    local id = channelId()
    if not id then return false end
    if not force and GetTime() - lastSend < 20 then return false end
    lastSend = GetTime()
    SendChatMessage(msg, "CHANNEL", nil, id)
    return true
end

-- keep the carrier lines out of every chat window
table.insert(W.chatFilters, function(ev)
    if ev ~= "CHAT_MSG_CHANNEL" and ev ~= "CHAT_MSG_CHANNEL_NOTICE"
        and ev ~= "CHAT_MSG_CHANNEL_JOIN" and ev ~= "CHAT_MSG_CHANNEL_LEAVE" then return false end
    local name = string.lower(arg9 or arg4 or "")
    return strfind(name, string.lower(CHANNEL), 1, 1) ~= nil
end)

-- -- Listings ------------------------------------------------------------------

function G:Add(guild, focus, minLevel, members, pitch, poster)
    if not guild or guild == "" then return end
    -- shown literally: another client could send colour codes or fake chat lines
    guild = string.gsub(guild, "|", "||")
    pitch = string.gsub(pitch or "", "|", "||")
    local isNew = not self.listings[guild]
    self.listings[guild] = {
        guild = guild, focus = focus ~= "" and focus or "Social", minLevel = tonumber(minLevel) or 1,
        members = tonumber(members), pitch = pitch or "", poster = poster, t = GetTime(),
    }
    if isNew and poster ~= UnitName("player") and W:IsActive(ID) and W:Setting(ID, "showAnnouncements", true) then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00e5ff[Guilds]|r |cffffd100<" .. guild .. ">|r is recruiting ("
            .. self.listings[guild].focus .. "): " .. (pitch or ""))
    end
    self.dirty = true
end

function G:Visible()
    local now = GetTime()
    local want = FOCUS[self.filter]
    local q = self.search and self.search ~= "" and string.lower(self.search)
    local list = {}
    for k, l in pairs(self.listings) do
        if now - l.t > TTL then
            self.listings[k] = nil
        elseif (want == "Any" or l.focus == want) and (not q or strfind(string.lower(l.guild), q, 1, 1)
            or strfind(string.lower(l.pitch), q, 1, 1)) then
            table.insert(list, l)
        end
    end
    table.sort(list, function(a, b) return a.t > b.t end)
    return list
end

function G:Broadcast(force)
    local p = myPost()
    if not p or not IsInGuild() then return end
    local guild = GetGuildInfo("player")
    if not guild then return end
    local members = GetNumGuildMembers and GetNumGuildMembers(true) or 0
    local msg = "CO1~L~" .. clean(guild) .. "~" .. clean(p.focus) .. "~" .. (tonumber(p.minLevel) or 1)
        .. "~" .. members .. "~" .. strsub(clean(p.pitch), 1, 150)
    if sendChannel(msg, force) then
        self:Add(guild, p.focus, p.minLevel, members, p.pitch, UnitName("player"))
        self.lastBroadcast = GetTime()
    end
end

function G:Receive(msg, from)
    local f, n = W.Split(msg, "~")
    if f[1] ~= "CO1" then return end
    if f[2] == "L" and n >= 7 then
        self:Add(f[3], f[4], f[5], f[6], f[7], from)
    elseif f[2] == "Q" and from ~= UnitName("player") then
        -- answer after a random pause so a crowd of listers does not reply at once
        if myPost() and (GetTime() - (self.lastBroadcast or 0)) > 60 then
            self.replyAt = GetTime() + 2 + math.random() * 8
        end
    end
end

-- -- Window ------------------------------------------------------------------------------------
-- The stock Character / Friends frame (UI.ClassicFrame) like the Social window: a round crest
-- portrait, a search box and Refresh in the header band, listings as bordered cards in the stock
-- list well, the focus filters as a strip of tabs at the top of the body (plus "My listing" for
-- guild members). The bottom row is left to the window tabs (Guild Finder | Friends, MicroMenu).
-- Every Guilds_* texture has a stock fallback, so the window looks right without the custom art.

local WIN_W, WIN_H = 460, 548
local FOCUS_H = 22                       -- the focus strip at the top of the body
local PAGE_W = WIN_W - 34                -- the Classic frame's body is 34 px narrower
local WELL_H = 410
local CARD_H, GAP, CARDS = 76, 4, 5
local CARD_W = PAGE_W - 22               -- room for the scroll track on the right
local PITCH_CHARS = 120                  -- about two lines of the card's pitch
local PORTRAIT = "Interface\\Icons\\INV_Shirt_GuildTabard_01"
local FOCUS_COLOR = {
    Raiding = { 1, 0.55, 0.25 }, Leveling = { 0.45, 0.9, 0.5 }, PvP = { 1, 0.36, 0.32 },
    Social = { 1, 0.80, 0.40 }, Casual = { 0.50, 0.72, 1 },
}
local TEXT = { 0.82, 0.80, 0.74 }
local CLASSIC_INSET = UI.SKINS and UI.SKINS.classic and UI.SKINS.classic.inset
local CARD_EDGE = CLASSIC_INSET or UI.BACKDROP
local strlower = string.lower

local function tabList()
    local t = {}
    for _, f in ipairs(FOCUS) do table.insert(t, { key = f, label = f == "Any" and "All" or f }) end
    if IsInGuild() then table.insert(t, { key = "mine", label = "My listing" }) end
    return t
end

-- the focus crest, or the stock icon in a thin black edge when the art is missing
local function setCrest(tex, edge, focus)
    if FOCUS_ICON[focus] and W:Art(tex, "Guilds_Focus_" .. focus, nil) then
        tex:SetTexCoord(0, 1, 0, 1)
        if edge then edge:Hide() end
        return true
    end
    tex:SetTexture(FOCUS_ICON[focus] or PORTRAIT)
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    if edge then edge:Show() end
    return false
end
G.SetCrest = setCrest

local function short(s, n)
    if string.len(s or "") <= n then return s or "" end
    s = strsub(s, 1, n - 3)
    local _, _, tail = strfind(s, "(|*)$")
    local k = string.len(tail)
    if k - 2 * math.floor(k / 2) == 1 then s = strsub(s, 1, -2) end   -- never split a "||"
    return W.Trim(s) .. "..."
end

local function inset(parent, h)
    local f = CreateFrame("Frame", nil, parent)
    if CLASSIC_INSET then
        -- the stock list well: dark, with the grey tooltip edge
        f:SetBackdrop(CLASSIC_INSET)
        f:SetBackdropColor(0, 0, 0, 0.55)
        f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    else
        UI.Skin(f, "inset")
    end
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    f:SetWidth(PAGE_W)
    f:SetHeight(h)
    return f
end

local function hl(row)
    -- the stock Friends list highlight bar
    local t = row:CreateTexture(nil, "HIGHLIGHT")
    t:SetPoint("TOPLEFT", row, "TOPLEFT", 3, -3)
    t:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -3, 3)
    t:SetTexture("Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar")
    t:SetBlendMode("ADD")
    return t
end

local function applyTo(l)
    if not l or not l.poster or l.poster == UnitName("player") then return end
    StaticPopup_Show("CONCORD_APPLY", l.poster, l.guild)
    G.applyTarget = l
end

StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs["CONCORD_APPLY"] = {
    text = "Whisper %s to ask about joining <%s>?",
    button1 = "Apply",
    button2 = CANCEL or "Cancel",
    OnAccept = function()
        local l = G.applyTarget
        if l then
            local lvl = UnitLevel("player")
            local _, class = UnitClass("player")
            SendChatMessage("[Guilds] Hi! I'd like to join <" .. l.guild .. ">. Level " .. lvl .. " "
                .. string.lower(class or "") .. ".", "WHISPER", nil, l.poster)
        end
    end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

-- a small bordered pill: chip:Set(text, {r,g,b})
local function chip(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetHeight(16)
    c:SetBackdrop(UI.THIN)
    c:SetBackdropColor(0.04, 0.04, 0.05, 0.9)
    c.text = UI.Label(c, 10, TEXT)
    c.text:SetPoint("CENTER", c, "CENTER", 0, 0)
    function c:Set(text, color)
        color = color or TEXT
        self.text:SetText(text)
        self.text:SetTextColor(color[1], color[2], color[3])
        self:SetBackdropBorderColor(color[1] * 0.7, color[2] * 0.7, color[3] * 0.7, 1)
        self:SetWidth(math.floor((self.text:GetStringWidth() or 30) + 14))
        self:Show()
    end
    return c
end

local function cardTooltip(card)
    local l = card.listing
    if not l then return end
    GameTooltip:SetOwner(card, "ANCHOR_RIGHT")
    GameTooltip:SetText("<" .. l.guild .. ">", 1, 0.82, 0)
    local c = FOCUS_COLOR[l.focus] or TEXT
    GameTooltip:AddLine(l.focus .. "  -  level " .. l.minLevel .. "+"
        .. (l.members and l.members > 0 and ("  -  " .. l.members .. " members") or ""), c[1], c[2], c[3])
    if l.pitch ~= "" then GameTooltip:AddLine(l.pitch, 1, 1, 1, 1) end
    if l.minLevel > (UnitLevel("player") or 1) then
        GameTooltip:AddLine("They ask for level " .. l.minLevel .. " or higher.", 1, 0.45, 0.4)
    end
    if l.poster == UnitName("player") then
        GameTooltip:AddLine("Your guild's listing.", 0.5, 0.9, 0.5)
    elseif l.poster then
        GameTooltip:AddLine("Posted by " .. l.poster .. ". Click to apply.", 0.7, 0.7, 0.7)
    else
        GameTooltip:AddLine("Listed by the realm.", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

-- one listing card: crest, <guild>, chips, two lines of pitch, Apply
local function makeCard(parent, name)
    local c = CreateFrame("Button", name, parent)
    c:SetWidth(CARD_W)
    c:SetHeight(CARD_H)
    c:SetBackdrop(CARD_EDGE)
    c:SetBackdropColor(0.10, 0.09, 0.08, 0.92)
    c:SetBackdropBorderColor(0.55, 0.50, 0.42, 1)
    c.hl = hl(c)
    c.stripe = c:CreateTexture(nil, "ARTWORK")
    c.stripe:SetWidth(2)
    c.stripe:SetPoint("TOPLEFT", c, "TOPLEFT", 4, -6)
    c.stripe:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 4, 6)
    c.edge = c:CreateTexture(nil, "BORDER")
    c.edge:SetTexture(0, 0, 0, 1)
    c.edge:SetWidth(42)
    c.edge:SetHeight(42)
    c.edge:SetPoint("TOPLEFT", c, "TOPLEFT", 12, -17)
    c.crest = c:CreateTexture(nil, "ARTWORK")
    c.crest:SetWidth(48)
    c.crest:SetHeight(48)
    c.crest:SetPoint("CENTER", c.edge, "CENTER", 0, 0)
    c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    c.name:SetPoint("TOPLEFT", c, "TOPLEFT", 68, -9)
    c.name:SetPoint("RIGHT", c, "RIGHT", -84, 0)
    c.name:SetJustifyH("LEFT")
    c.apply = UI.Button(c, "Apply", 66, 20, function() applyTo(c.listing) end)
    c.apply:SetPoint("TOPRIGHT", c, "TOPRIGHT", -8, -7)
    c.apply:SetScript("OnEnter", function() cardTooltip(c) end)
    c.apply:SetScript("OnLeave", function() GameTooltip:Hide() end)
    c.mine = UI.Label(c, 10, { 0.5, 0.9, 0.5 })
    c.mine:SetPoint("TOPRIGHT", c, "TOPRIGHT", -12, -12)
    c.mine:SetText("Your listing")
    c.chips = { chip(c), chip(c), chip(c) }
    c.chips[1]:SetPoint("TOPLEFT", c, "TOPLEFT", 68, -27)
    c.chips[2]:SetPoint("LEFT", c.chips[1], "RIGHT", 4, 0)
    c.chips[3]:SetPoint("LEFT", c.chips[2], "RIGHT", 4, 0)
    c.pitch = UI.Label(c, 10, TEXT)
    c.pitch:SetPoint("TOPLEFT", c, "TOPLEFT", 69, -47)
    c.pitch:SetWidth(CARD_W - 80)
    c.pitch:SetHeight(24)
    if c.pitch.SetJustifyV then c.pitch:SetJustifyV("TOP") end
    if c.pitch.SetNonSpaceWrap then c.pitch:SetNonSpaceWrap(false) end
    c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    c:SetScript("OnClick", function()
        local l = this.listing
        if arg1 == "RightButton" then
            -- report a listing (its poster) through the shared dialog
            if l and l.poster and l.poster ~= UnitName("player") and W.Report and UI.Menu then
                UI.Menu(this, { { text = "<" .. (l.guild or "?") .. ">", title = true },
                    { text = "Apply", func = function() applyTo(l) end },
                    { text = "Report " .. l.poster .. "...", color = { 1, 0.45, 0.4 }, func = function() W.Report.Open(l.poster, "guilds") end } })
            end
            return
        end
        applyTo(l)
    end)
    c:SetScript("OnEnter", function() cardTooltip(this) end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)

    function c:SetListing(l)
        self.listing = l
        local color = FOCUS_COLOR[l.focus] or TEXT
        self.stripe:SetTexture(color[1], color[2], color[3], 0.85)
        self.art = setCrest(self.crest, self.edge, l.focus)
        if not self.art then self.crest:SetWidth(40); self.crest:SetHeight(40)
        else self.crest:SetWidth(48); self.crest:SetHeight(48) end
        self.name:SetText("<" .. l.guild .. ">")
        self.chips[1]:Set(l.focus, color)
        local low = l.minLevel > (UnitLevel("player") or 1)
        self.chips[2]:Set("Level " .. l.minLevel .. "+", low and { 1, 0.45, 0.4 } or { 0.86, 0.86, 0.86 })
        if l.members and l.members > 0 then
            self.chips[3]:Set(l.members .. " member" .. (l.members == 1 and "" or "s"), { 0.70, 0.78, 0.92 })
        else
            self.chips[3]:Hide()
        end
        self.pitch:SetText(l.pitch ~= "" and short(l.pitch, PITCH_CHARS) or "|cff8a8d96No pitch given.|r")
        if l.poster == UnitName("player") then
            self.apply:Hide(); self.mine:Show()
        else
            self.mine:Hide(); self.apply:Show()
            if l.poster then self.apply:Enable() else self.apply:Disable() end
        end
        self:Show()
    end
    c:Hide()
    return c
end

local board = UI.ClassicFrame("Concord_Frame", {
    width = WIN_W, height = WIN_H, title = "Guild Finder", strata = "HIGH",
    portrait = PORTRAIT, portraitArt = "Guilds_Portrait",
    point = { "LEFT", UIParent, "LEFT", 60, 40 },
})
-- the focus filters: top tabs in the body (bottom tabs here collided with the window tabs)
board.tabs = UI.Tabs(board.body, { tabs = tabList(), onSelect = function(key) G:ShowTab(key) end, skin = true, height = FOCUS_H })
board.tabs:SetPoint("TOPLEFT", board.body, "TOPLEFT", 0, 0)
board:EnableMouseWheel(true)
table.insert(UISpecialFrames, "Concord_Frame")
board:Hide()
G.board = board
local ui = {}
G.ui = ui

-- list page
local listPage = CreateFrame("Frame", "Concord_ListPage", board.body)
listPage:SetPoint("TOPLEFT", board.body, "TOPLEFT", 0, -(FOCUS_H + 6))
listPage:SetPoint("BOTTOMRIGHT", board.body, "BOTTOMRIGHT", 0, 0)
local well = inset(listPage, WELL_H)
ui.well = well

local cards = {}
for i = 1, CARDS do
    local c = makeCard(well, "Concord_Card" .. i)
    c:SetPoint("TOPLEFT", well, "TOPLEFT", 6, -6 - (i - 1) * (CARD_H + GAP))
    cards[i] = c
end
ui.cards = cards

local track = well:CreateTexture(nil, "ARTWORK")
track:SetTexture(0, 0, 0, 0.45)
track:SetWidth(6)
track:SetPoint("TOPRIGHT", well, "TOPRIGHT", -6, -7)
track:SetHeight(CARDS * (CARD_H + GAP) - GAP - 2)
local thumb = well:CreateTexture(nil, "OVERLAY")
thumb:SetTexture(0.62, 0.52, 0.32, 0.9)
thumb:SetWidth(4)
ui.thumb = thumb

board:SetScript("OnMouseWheel", function()
    G.scroll = G.scroll - (arg1 or 0)
    G:Render()
end)

-- empty state: a dimmed round emblem above the line, and a hint under it
local empty = UI.Label(well, 12, { 0.92, 0.86, 0.66 })
empty:SetPoint("CENTER", well, "CENTER", 0, -6)
empty:SetJustifyH("CENTER")
local emptyHint = UI.Label(well, 10, UI.MUTED)
emptyHint:SetPoint("TOP", empty, "BOTTOM", 0, -6)
emptyHint:SetWidth(PAGE_W - 80)
emptyHint:SetJustifyH("CENTER")
-- SetPortraitToTexture by the texture's name (the browser engine takes the name, not the object);
-- falls back to a square SetTexture when neither works
local function roundPortrait(t, path)
    if SetPortraitToTexture and path then
        local n = t.GetName and t:GetName()
        if (n and pcall(SetPortraitToTexture, n, path)) or pcall(SetPortraitToTexture, t, path) then return true end
    end
    t:SetTexture(path)
end
local emptyArt = well:CreateTexture("Concord_EmptyArt", "ARTWORK")
emptyArt:SetWidth(60)
emptyArt:SetHeight(60)
emptyArt:SetPoint("BOTTOM", empty, "TOP", 0, 16)
if not W:Art(emptyArt, "Guilds_Portrait", nil) then
    roundPortrait(emptyArt, PORTRAIT)
end
emptyArt:SetAlpha(0.5)
local emptyRing = well:CreateTexture(nil, "OVERLAY")
emptyRing:SetWidth(82)
emptyRing:SetHeight(82)
emptyRing:SetPoint("CENTER", emptyArt, "CENTER", 0, 0)
emptyRing:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
emptyRing:SetTexCoord(0, 0.6, 0, 0.6)
emptyRing:SetAlpha(0.8)
ui.empty, ui.emptyHint, ui.emptyArt, ui.emptyRing = empty, emptyHint, emptyArt, emptyRing

local footer = UI.Label(listPage, 10, UI.MUTED)
footer:SetPoint("TOPLEFT", listPage, "TOPLEFT", 4, -WELL_H - 6)
footer:SetText("Apply whispers the officer who posted the listing.")

-- header band: search, count, Refresh
local search = UI.SearchBox(board.toolbar, { name = "Concord_Search", width = 140, placeholder = "Search guilds",
    onChange = function(t)
        G.search = t
        G.scroll = 0
        if G.built then G:Render() end
    end })
search:SetMaxLetters(30)
search:SetPoint("LEFT", board.toolbar, "LEFT", 4, 0)
local count = board.toolbar:CreateFontString("Concord_Count", "OVERLAY", "GameFontNormalSmall")
count:SetPoint("LEFT", search, "RIGHT", 10, 0)
local refreshBtn = UI.Button(board.toolbar, "Refresh", 72, 20, function()
    sendChannel("CO1~Q", true)
    G:Render()
end)
refreshBtn:SetPoint("RIGHT", board.toolbar, "RIGHT", -4, 0)
ui.search, ui.count, ui.refresh = search, count, refreshBtn

-- -- My listing page -----------------------------------------------------------------------

local form = CreateFrame("Frame", "Concord_PostForm", board.body)
form:SetPoint("TOPLEFT", board.body, "TOPLEFT", 0, -(FOCUS_H + 6))
form:SetPoint("BOTTOMRIGHT", board.body, "BOTTOMRIGHT", 0, 0)
form:Hide()
form.focus = 2
local fwell = inset(form, WELL_H)

local who = UI.Label(fwell, 10, UI.MUTED)
who:SetPoint("TOPLEFT", fwell, "TOPLEFT", 14, -12)
who:SetText("Recruiting for")
local myGuild = fwell:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
myGuild:SetPoint("TOPLEFT", who, "BOTTOMLEFT", 0, -3)
local status = UI.Label(fwell, 10, UI.MUTED)
status:SetPoint("TOPRIGHT", fwell, "TOPRIGHT", -14, -14)
status:SetJustifyH("RIGHT")

local focusLabel = fwell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
focusLabel:SetPoint("TOPLEFT", fwell, "TOPLEFT", 14, -56)
focusLabel:SetText("Focus")
form.picks = {}
for i = 2, table.getn(FOCUS) do
    local key, idx = FOCUS[i], i
    local b = CreateFrame("Button", "Concord_PostFocus" .. (i - 1), fwell)
    b:SetWidth(44)
    b:SetHeight(44)
    b:SetPoint("TOPLEFT", fwell, "TOPLEFT", 26 + (i - 2) * 78, -72)
    b.glow = b:CreateTexture(nil, "BACKGROUND")
    b.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    b.glow:SetBlendMode("ADD")
    b.glow:SetWidth(82)
    b.glow:SetHeight(82)
    b.glow:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.edge = b:CreateTexture(nil, "BORDER")
    b.edge:SetTexture(0, 0, 0, 1)
    b.edge:SetPoint("TOPLEFT", b, "TOPLEFT", 3, -3)
    b.edge:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, 3)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints(b)
    b.label = UI.Label(fwell, 10, TEXT)
    b.label:SetPoint("TOP", b, "BOTTOM", 0, -3)
    b.label:SetJustifyH("CENTER")
    b.label:SetText(key)
    b:SetScript("OnClick", function()
        form.focus = idx
        G:PaintForm()
    end)
    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_TOP")
        GameTooltip:SetText(key, 1, 0.82, 0)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b.key, b.index = key, idx
    form.picks[idx] = b
end

local lvlLabel = fwell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
lvlLabel:SetPoint("TOPLEFT", fwell, "TOPLEFT", 14, -148)
lvlLabel:SetText("Minimum level")
local lvl = UI.SearchBox(fwell, { name = "Concord_PostLevel", width = 40, placeholder = "1",
    onChange = function() if G.PaintForm then G:PaintForm() end end })
lvl:SetPoint("LEFT", lvlLabel, "RIGHT", 10, 0)
lvl:SetMaxLetters(2)
lvl:SetNumeric(true)

local pitchLabel = fwell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
pitchLabel:SetPoint("TOPLEFT", fwell, "TOPLEFT", 14, -176)
pitchLabel:SetText("Pitch")
local pitchCount = UI.Label(fwell, 10, UI.MUTED)
pitchCount:SetPoint("TOPRIGHT", fwell, "TOPRIGHT", -14, -177)
pitchCount:SetJustifyH("RIGHT")
local pitchBox = UI.SearchBox(fwell, { name = "Concord_PostPitch", width = PAGE_W - 28,
    placeholder = "Raid times, goals, what you're looking for",
    onChange = function() if G.PaintForm then G:PaintForm() end end })
pitchBox:SetPoint("TOPLEFT", pitchLabel, "BOTTOMLEFT", 0, -5)
pitchBox:SetHeight(20)
pitchBox:SetMaxLetters(150)

local previewLabel = fwell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
previewLabel:SetPoint("TOPLEFT", fwell, "TOPLEFT", 14, -230)
previewLabel:SetText("Preview")
local preview = makeCard(fwell, "Concord_PostPreview")
preview:SetPoint("TOPLEFT", fwell, "TOPLEFT", 6, -246)
preview:SetWidth(CARD_W + 10)
preview:EnableMouse(false)
form.preview = preview

local postNow = UI.Button(fwell, "Post", 96, 22, function()
    local c = WenillaCore_Config
    if not c then return end
    c.concord = c.concord or {}
    c.concord[UnitName("player") or "?"] = {
        focus = FOCUS[form.focus], minLevel = tonumber(lvl:GetText()) or 1, pitch = pitchBox:GetText() or "",
    }
    G:Broadcast(true)
    G:ShowTab(FOCUS[G.filter])
end)
postNow:SetPoint("BOTTOMLEFT", fwell, "BOTTOMLEFT", 12, 12)
local unlist = UI.Button(fwell, "Remove", 96, 22, function()
    local c = WenillaCore_Config
    if c and c.concord then c.concord[UnitName("player") or "?"] = nil end
    local guild = GetGuildInfo("player")
    if guild then G.listings[guild] = nil end
    G:ShowTab(FOCUS[G.filter])
end)
unlist:SetPoint("LEFT", postNow, "RIGHT", 8, 0)
local postNote = UI.Label(fwell, 10, UI.MUTED)
postNote:SetPoint("BOTTOMRIGHT", fwell, "BOTTOMRIGHT", -14, 17)
postNote:SetJustifyH("RIGHT")
postNote:SetText("Re-sent every 10 minutes while listed.")
ui.form, ui.post, ui.remove, ui.status = form, postNow, unlist, status

function G:PaintForm()
    if not form:IsShown() then return end
    for i, b in pairs(form.picks) do
        local art = setCrest(b.icon, b.edge, b.key)
        local on = (i == form.focus)
        if on then b.glow:Show() else b.glow:Hide() end
        b.icon:SetAlpha(on and 1 or 0.55)
        if b.icon.SetDesaturated then b.icon:SetDesaturated(not on) end
        local c = on and (FOCUS_COLOR[b.key] or TEXT) or UI.MUTED
        b.label:SetTextColor(c[1], c[2], c[3])
    end
    local guild = GetGuildInfo("player") or "?"
    myGuild:SetText("<" .. guild .. ">")
    local live = myPost() and self.listings[guild]
    status:SetText(live and "|cff60e060Listed on the board|r" or "Not listed yet")
    if myPost() then unlist:Show() else unlist:Hide() end
    local text = pitchBox:GetText() or ""
    pitchCount:SetText(string.len(text) .. " / 150")
    preview:SetListing({
        guild = string.gsub(guild, "|", "||"), focus = FOCUS[form.focus], minLevel = tonumber(lvl:GetText()) or 1,
        members = GetNumGuildMembers and GetNumGuildMembers(true) or nil, pitch = string.gsub(text, "|", "||"),
        poster = UnitName("player"),
    })
end

-- -- Tabs and render ------------------------------------------------------------------------

function G:ShowTab(key)
    if key == "mine" and not IsInGuild() then key = FOCUS[self.filter] end
    self.page = (key == "mine") and "mine" or "list"
    if key ~= "mine" then
        for i, f in ipairs(FOCUS) do if f == key then self.filter = i end end
        self.scroll = 0
    end
    if board.tabs:Selected() ~= key then board.tabs:Select(key, true) end
    if self.page == "mine" then
        local p = myPost()
        form.focus = 2
        if p then
            for i, f in ipairs(FOCUS) do if f == p.focus and i > 1 then form.focus = i end end
            lvl:SetText(p.minLevel or 1)
            pitchBox:SetText(p.pitch or "")
        else
            lvl:SetText("1")
            pitchBox:SetText("")
        end
        listPage:Hide()
        form:Show()
        self:PaintForm()
    else
        form:Hide()
        listPage:Show()
    end
    self:Render()
end

function G:TogglePostForm()
    if self.page == "mine" then self:ShowTab(FOCUS[self.filter]) else self:ShowTab("mine") end
end

function G:Render()
    self.dirty = false
    -- "My listing" comes and goes with guild membership
    local inGuild = IsInGuild() and true or false
    if inGuild ~= self.tabsGuild then
        self.tabsGuild = inGuild
        board.tabs:SetTabs(tabList())
        if not inGuild and self.page == "mine" then self:ShowTab(FOCUS[self.filter]) return end
        board.tabs:Select(self.page == "mine" and "mine" or FOCUS[self.filter], true)
    end
    if self.page == "mine" then
        count:SetText("")
        self:PaintForm()
        return
    end
    local list = self:Visible()
    local n = table.getn(list)
    local maxScroll = n - CARDS
    if maxScroll < 0 then maxScroll = 0 end
    if self.scroll > maxScroll then self.scroll = maxScroll end
    if self.scroll < 0 then self.scroll = 0 end
    local searching = self.search and self.search ~= ""
    count:SetText(n .. " guild" .. (n == 1 and "" or "s") .. (searching and " found" or " recruiting"))
    for i = 1, CARDS do
        local c, l = cards[i], list[i + self.scroll]
        if l then c:SetListing(l) else c.listing = nil; c:Hide() end
    end
    local on = (n == 0)
    if on then
        if not channelId() then
            empty:SetText("Connecting to the recruitment board...")
            emptyHint:SetText("Listings appear here once the board is reached.")
        elseif searching then
            empty:SetText("No guilds match \"" .. string.gsub(self.search, "|", "||") .. "\"")
            emptyHint:SetText("Try another word, or clear the search.")
        elseif FOCUS[self.filter] ~= "Any" then
            empty:SetText("No " .. FOCUS[self.filter] .. " guilds are recruiting right now")
            emptyHint:SetText("Check the All tab, or Refresh in a minute.")
        else
            empty:SetText("No guilds are recruiting right now")
            emptyHint:SetText(IsInGuild() and "Guild officers: post yours from the My listing tab."
                or "Listings appear here as guilds post them. Try Refresh in a minute.")
        end
    end
    for _, x in ipairs({ empty, emptyHint, emptyArt, emptyRing }) do if on then x:Show() else x:Hide() end end
    if n > CARDS then
        local h = CARDS * (CARD_H + GAP) - GAP - 2
        local th = math.max(16, h * CARDS / n)
        thumb:SetHeight(th)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", track, "TOP", 0, -(h - th) * self.scroll / maxScroll)
        thumb:Show()
        track:Show()
    else
        thumb:Hide()
        track:Hide()
    end
end

board:SetScript("OnShow", function()
    if not G.asked or GetTime() - G.asked > 300 then
        G.asked = GetTime()
        sendChannel("CO1~Q", true)
    end
    if PlaySound then PlaySound("igCharacterInfoOpen") end
    G:Render()
end)
board:SetScript("OnHide", function()
    if PlaySound then PlaySound("igCharacterInfoClose") end
end)
G.page = "list"
G.built = true

-- -- Chat tab ------------------------------------------------------------------

local tab = CreateFrame("Button", "ChatFrame_GuildTab", UIParent)
ChatFrame_ConcordTab = tab
tab:SetWidth(56)
tab:SetHeight(20)
tab:SetBackdrop(UI.THIN)
tab:SetBackdropColor(0.05, 0.08, 0.05, 0.85)
tab:SetBackdropBorderColor(0.25, 0.75, 0.35, 0.85)
local tabText = tab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
tabText:SetPoint("CENTER", tab, "CENTER", 0, 0)
tabText:SetText("|cff40ff40Guild|r")
tab:RegisterForClicks("LeftButtonUp", "RightButtonUp")
tab:SetScript("OnClick", function()
    if arg1 == "RightButton" then
        -- hide it; it comes back from any chat tab's right-click menu (or /cpchat guild)
        W:Settings(ID).showChatTab = false
        GameTooltip:Hide()
        W.Print("Guild tab hidden. Right-click a chat tab and tick \"Show the Guild tab\" to bring it back.")
        return
    end
    if board:IsShown() then board:Hide() else board:Show() end
end)

local isMouseOverTab = false
tab:SetScript("OnEnter", function()
    isMouseOverTab = true
    tab:SetBackdropColor(0.08, 0.14, 0.08, 0.95)
    tab:SetBackdropBorderColor(0.40, 1.0, 0.50, 1.0)
    tabText:SetText("|cff80ff80Guild|r")
    GameTooltip:SetOwner(this, "ANCHOR_TOP")
    GameTooltip:SetText("Guild", 0.25, 1.0, 0.25)
    GameTooltip:AddLine("Guild recruitment and roster", 0.85, 0.85, 0.85)
    GameTooltip:AddLine("Click to toggle Guild board", 0.5, 0.8, 0.5)
    GameTooltip:AddLine("Right-click to hide this tab", 0.5, 0.5, 0.5)
    GameTooltip:Show()
    if ChatFrame1 then
        ChatFrame1.hover = 1
        ChatFrame1.hoverTime = (CHAT_TAB_SHOW_DELAY or 0.2) + 1
        if ChatFrame1Tab then
            ChatFrame1Tab:Show()
            ChatFrame1Tab:SetAlpha(1)
        end
    end
end)
tab:SetScript("OnLeave", function()
    isMouseOverTab = false
    tab:SetBackdropColor(0.05, 0.08, 0.05, 0.85)
    tab:SetBackdropBorderColor(0.25, 0.75, 0.35, 0.85)
    tabText:SetText("|cff40ff40Guild|r")
    GameTooltip:Hide()
    if ChatFrame1 then
        ChatFrame1.hover = nil
        ChatFrame1.hoverTime = 0
    end
end)

local function placeTab()
    tab:ClearAllPoints()
    local anchor
    for i = (NUM_CHAT_WINDOWS or 7), 1, -1 do
        local t = getglobal("ChatFrame" .. i .. "Tab")
        if t and t:IsShown() and t:GetRight() and t:GetRight() > 0 then
            anchor = t
            break
        end
    end
    if not anchor and ChatFrame1Tab then
        anchor = ChatFrame1Tab
    end

    if anchor then
        tab:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", 4, 2)
    elseif ChatFrame1 then
        tab:SetPoint("BOTTOMLEFT", ChatFrame1, "TOPLEFT", 140, 6)
    else
        tab:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 180, 200)
    end
end

-- Synchronize fading with chat tabs (fades and hides when mouse is not hovering chat)
local lastAlpha = 0
local lastAnchorX = -1
tab:SetAlpha(0)
tab:EnableMouse(false)

tab:SetScript("OnUpdate", function()
    local s = W:Settings(ID)
    if not W:IsActive(ID) or (s and s.showChatTab == false) then
        if tab:GetAlpha() > 0 then
            tab:SetAlpha(0)
            tab:EnableMouse(false)
            lastAlpha = 0
        end
        return
    end

    local ref = ChatFrame1Tab
    if isMouseOverTab then
        if lastAlpha ~= 1 then
            tab:SetAlpha(1)
            tab:EnableMouse(true)
            lastAlpha = 1
        end
        return
    end

    if not ref or not ref:IsShown() or ref:GetAlpha() <= 0.05 then
        if lastAlpha > 0 then
            tab:SetAlpha(0)
            tab:EnableMouse(false)
            lastAlpha = 0
        end
    else
        local a = ref:GetAlpha()
        if math.abs(a - lastAlpha) > 0.01 then
            tab:SetAlpha(a)
            tab:EnableMouse(true)
            lastAlpha = a
        end
        local rx = ref:GetRight() or 0
        if rx ~= lastAnchorX then
            lastAnchorX = rx
            placeTab()
        end
    end
end)

-- -- Events --------------------------------------------------------------------

local ev = CreateFrame("Frame", "Concord_Events")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_CHANNEL")
ev:RegisterEvent("PLAYER_GUILD_UPDATE")
ev:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        G.joinAt = GetTime() + 6     -- after the default channels have their numbers
        placeTab()
    elseif event == "CHAT_MSG_CHANNEL" then
        if strfind(string.lower(arg9 or arg4 or ""), string.lower(CHANNEL), 1, 1) then
            G:Receive(arg1 or "", arg2)
        end
    elseif event == "PLAYER_GUILD_UPDATE" then
        G.dirty = true
    end
end)

local acc = 0
ev:SetScript("OnUpdate", function()
    acc = acc + arg1
    if acc < 1 then return end
    acc = 0
    if not W:IsActive(ID) then return end
    local now = GetTime()
    if G.joinAt and now >= G.joinAt then
        G.joinAt = nil
        joinChannel()
        placeTab()
    end
    if G.replyAt and now >= G.replyAt then
        G.replyAt = nil
        G:Broadcast(true)
    end
    if myPost() and now - (G.lastBroadcast or 0) > 600 then G:Broadcast(false) end
    if G.dirty and board:IsShown() then G:Render() end
end)

-- -- Server packets (CO) -------------------------------------------------------

W:RegisterModule("CO", function(body)
    if strsub(body, 1, 13) == "announcement," then
        if W:Setting(ID, "showAnnouncements", true) then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00e5ff[Guilds]|r " .. strsub(body, 14))
        end
        return
    end
    local recs, n = W.Split(body, ";")
    for i = 1, n do
        local f, m = W.Split(recs[i], "~")
        if f[1] == "L" and m >= 6 then G:Add(f[2], f[3], f[4], f[5], f[6], f[7]) end
    end
end)

W:RegisterAddon(ID, function(active)
    if active and W:Setting(ID, "showChatTab", true) then
        placeTab()
        tab:Show()
    else
        tab:Hide()
    end
    if not active then board:Hide() end
end)

SLASH_GUILDS1 = "/guilds"
SLASH_GUILDS2 = "/concord"
SlashCmdList["GUILDS"] = function()
    if not W:IsActive(ID) then W.Print("Guilds is switched off. Turn it on in /addons.") return end
    if board:IsShown() then board:Hide() else board:Show() end
end
