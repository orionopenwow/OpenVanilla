--[[
    GuildHub/Window.lua  -  the Guild Hub window: the stock Character / Friends frame
    (UI.ClassicFrame) with six bottom tabs, sub-tabs in the header band, and the guild's status.

      Roster    search, rank promote/demote arrows, public and officer notes, last online,
                professions, main/alt links, DKP; click a member for the menu; Export (copyable)
      Recruit   Listing: the Guilds board's post form, embedded; Applications: the "[Guilds]"
                whispers with Accept (guild invite) / Decline / Note / Whisper
      Events    a week of guild events; officers add them; sign up as tank / healer / damage,
                tentative or decline; post an event to guild chat; reminders 30 and 5 min before
      Bank      Log: deposits and withdrawals of the banker alt with the running balance (trades
                with the banker log themselves); Requests: ask the bank for something
      DKP       Standings (award, tick the raid, export), Loot, History, Council (officer votes)
      Guild     MOTD composer with templates, Officer chat, Achievements summary, Setup

    Officer-only parts follow the game's own permissions (CanEditOfficerNote, CanGuildPromote,
    CanGuildInvite, CanEditMOTD) and the guild's officer rank (Guild > Setup).
        /guildhub, /gh  [roster|recruit|apps|events|bank|requests|dkp|loot|council|motd|officer|setup|tick]
    Art: GuildHub_* (tools/gen_guildhub_art.py), every piece with a stock fallback.
]]--

local W = WenillaCore
local UI = W.UI
local G = GuildHub
local ID = G.ID

local strfind, strsub, strgsub, strlen, strlower = string.find, string.sub, string.gsub, string.len, string.lower
local tinsert, getn = table.insert, table.getn
local floor = math.floor
local me, now, blank = G.Me, G.Now, G.Blank
local DOT = G.DOT
local plain = G.Plain

local WIN_W, WIN_H = 620, 540
local PAGE_W = WIN_W - 34
local PORTRAIT = "Interface\\Icons\\INV_BannerPVP_02"
local MUTED = UI.MUTED
local TEXT = { 0.86, 0.85, 0.80 }
local GREEN, RED, BLUE = { 0.40, 0.92, 0.50 }, { 1, 0.42, 0.38 }, { 0.50, 0.75, 1 }
local CLASSIC_INSET = UI.SKINS and UI.SKINS.classic and UI.SKINS.classic.inset

local TABS = {
    { key = "roster", label = "Roster", icon = "Interface\\Icons\\INV_Misc_GroupNeedMore", title = "Roster" },
    { key = "recruit", label = "Recruit", icon = "Interface\\Icons\\INV_Letter_15", title = "Recruitment" },
    { key = "events", label = "Events", icon = "Interface\\Icons\\INV_Misc_PocketWatch_01", title = "Events" },
    { key = "bank", label = "Bank", icon = "Interface\\Icons\\INV_Misc_Bag_10", title = "Bank log" },
    { key = "dkp", label = "DKP", icon = "Interface\\Icons\\INV_Misc_Coin_02", title = "DKP & loot" },
    { key = "guild", label = "Guild", icon = "Interface\\Icons\\INV_Scroll_03", title = "Guild" },
}
local ART = { roster = "Roster", recruit = "Recruit", events = "Events", bank = "Bank", dkp = "DKP", guild = "Guild" }
local SUBS = {
    recruit = { { key = "listing", label = "Listing" }, { key = "apps", label = "Applications" } },
    bank = { { key = "log", label = "Log" }, { key = "requests", label = "Requests" } },
    dkp = { { key = "standings", label = "Standings" }, { key = "loot", label = "Loot" }, { key = "history", label = "History" },
        { key = "council", label = "Council" } },
    guild = { { key = "motd", label = "MOTD" }, { key = "officer", label = "Officer chat" }, { key = "achievements", label = "Achievements" },
        { key = "setup", label = "Setup" } },
}

G.tab = "roster"
G.sub = { recruit = "listing", bank = "log", dkp = "standings", guild = "motd" }
local ui = {}
G.ui = ui

-- -- Pieces --------------------------------------------------------------------------------------

local function inset(parent, x, y, w, h)
    local f = CreateFrame("Frame", nil, parent)
    if CLASSIC_INSET then
        f:SetBackdrop(CLASSIC_INSET)
        f:SetBackdropColor(0, 0, 0, 0.55)
        f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    else
        UI.Skin(f, "inset")
    end
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    f:SetWidth(w)
    f:SetHeight(h)
    return f
end

local function hl(row)
    local t = row:CreateTexture(nil, "HIGHLIGHT")
    t:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
    t:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
    t:SetTexture("Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar")
    t:SetBlendMode("ADD")
    return t
end

local function label(parent, size, color, x, y, w)
    local l = UI.Label(parent, size or 10, color or TEXT)
    if x then l:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y) end
    if w then l:SetWidth(w) end
    return l
end

local function box(parent, name, w, max, placeholder, onChange)
    local e = UI.SearchBox(parent, { name = name, width = w, placeholder = placeholder, onChange = onChange })
    e:SetMaxLetters(max or 60)
    return e
end

local function button(parent, text, w, h, fn) return UI.Button(parent, text, w, h or 20, fn) end

local function show(f, on) if on then f:Show() else f:Hide() end end

local function arrow(parent, dir, tip, fn)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(22)
    b:SetHeight(22)
    local base = "Interface\\ChatFrame\\UI-ChatIcon-Scroll" .. dir
    b:SetNormalTexture(base .. "-Up")
    b:SetPushedTexture(base .. "-Down")
    b:SetDisabledTexture(base .. "-Disabled")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    b:SetScript("OnClick", fn)
    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText(tip(), 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function rankName(i)
    return GuildControlGetRankName and GuildControlGetRankName(i + 1) or ("Rank " .. i)
end

local function memberToken(name)
    local m = G:Member(name)
    if m then return m.token end
    local a = G.GDB().ap[name or ""]
    return a and G.Token(a.class)
end

-- -- The window --------------------------------------------------------------------------------

local win = UI.ClassicFrame("GuildHub_Frame", {
    width = WIN_W, height = WIN_H, title = "Guild Hub", strata = "HIGH",
    portrait = PORTRAIT, portraitArt = "GuildHub_Portrait",
    point = { "LEFT", UIParent, "LEFT", 80, 30 },
    tabs = TABS, onTab = function(key) G:Show(key) end,
})
win:Hide()
tinsert(UISpecialFrames, "GuildHub_Frame")
ui.win = win

ui.subtabs = UI.Tabs(win.toolbar, { height = 20, onSelect = function(key) G:Show(G.tab, key) end })
ui.subtabs:SetPoint("LEFT", win.toolbar, "LEFT", 4, 0)
ui.status = UI.Label(win.toolbar, 10, MUTED)
ui.status:SetPoint("RIGHT", win.toolbar, "RIGHT", -6, 0)
ui.status:SetJustifyH("RIGHT")

function ui.SetUnread(key)
    if G.tab ~= key or not win:IsShown() then win.tabs:SetUnread(key, true) end
end

-- each page: a header with the tab's crest, title and a hint
ui.pages = {}
local function page(t)
    local p = CreateFrame("Frame", "GuildHub_Page_" .. t.key, win.body)
    p:SetAllPoints(win.body)
    p:Hide()
    p.icon = p:CreateTexture(nil, "ARTWORK")
    p.icon:SetWidth(22)
    p.icon:SetHeight(22)
    p.icon:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
    if not W:Art(p.icon, "GuildHub_Tab_" .. ART[t.key], t.icon) then p.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    p.title = UI.Label(p, 13, UI.ACCENT, "OUTLINE")
    p.title:SetPoint("LEFT", p.icon, "RIGHT", 6, 0)
    p.title:SetText(t.title)
    p.hint = UI.Label(p, 10, MUTED)
    p.hint:SetPoint("TOPRIGHT", p, "TOPRIGHT", -2, -6)
    p.hint:SetJustifyH("RIGHT")
    ui.pages[t.key] = p
    return p
end

-- "not in a guild" covers every page
local none = CreateFrame("Frame", "GuildHub_NoGuild", win.body)
none:SetAllPoints(win.body)
none:Hide()
ui.none = none
local noneText = UI.Label(none, 12, { 0.92, 0.86, 0.66 })
noneText:SetPoint("CENTER", none, "CENTER", 0, 20)
noneText:SetJustifyH("CENTER")
noneText:SetText("You're not in a guild.")
local noneHint = UI.Label(none, 10, MUTED)
noneHint:SetPoint("TOP", noneText, "BOTTOM", 0, -6)
noneHint:SetText("The Guilds board lists the guilds that are recruiting.")
local noneBtn = button(none, "Find a guild", 110, 22, function()
    local fn = SlashCmdList and SlashCmdList["GUILDS"]
    if fn then fn("") end
end)
noneBtn:SetPoint("TOP", noneHint, "BOTTOM", 0, -12)

-- -- Export window (copyable text) ---------------------------------------------------------------

local export = UI.Window("GuildHub_Export", { width = 460, height = 320, title = "Guild Hub export", strata = "DIALOG",
    point = { "CENTER", UIParent, "CENTER", 0, 40 } })
export:Hide()
tinsert(UISpecialFrames, "GuildHub_Export")
local exportEdit = CreateFrame("EditBox", "GuildHub_ExportText", export)
exportEdit:SetMultiLine(true)
exportEdit:SetAutoFocus(false)
exportEdit:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
exportEdit:SetPoint("TOPLEFT", export, "TOPLEFT", 12, -32)
exportEdit:SetWidth(436)
exportEdit:SetHeight(250)
exportEdit:SetMaxLetters(0)
exportEdit:SetScript("OnEscapePressed", function() export:Hide() end)
local exportHint = UI.Label(export, 10, MUTED)
exportHint:SetPoint("BOTTOMLEFT", export, "BOTTOMLEFT", 12, 10)
exportHint:SetText("Ctrl+C copies the selected text. Paste it into a spreadsheet or Discord.")
ui.export, ui.exportEdit = export, exportEdit

function G:ShowExport(title, text)
    export.title:SetText(title)
    export:Show()
    exportEdit:SetText(text or "")
    exportEdit:SetFocus()
    exportEdit:HighlightText()
end

-- -- Roster -------------------------------------------------------------------------------------

local function memberMenu(anchor, m)
    if not m then return end
    local name = m.name
    local items = { { text = plain(name) .. "  " .. m.level .. " " .. (G.CLASS_NAME[m.token or ""] or ""), title = true } }
    if name ~= me() then
        tinsert(items, { text = "Whisper", func = function() if ChatFrame_OpenChat then ChatFrame_OpenChat("/w " .. name .. " ") end end })
        if m.online then tinsert(items, { text = "Invite to group", func = function() InviteByName(name) end }) end
    end
    if G:CanPromoteMember(m) then tinsert(items, { text = "Promote to " .. rankName(m.rankIndex - 1), func = function() G:Promote(name) end }) end
    if G:CanDemoteMember(m) then tinsert(items, { text = "Demote to " .. rankName(m.rankIndex + 1), func = function() G:Demote(name) end }) end
    if G:CanPublicNote() then
        tinsert(items, { text = "Public note...", func = function()
            UI.Prompt({ title = "Public note", text = name .. " (31 letters, everyone sees it)", default = m.note, maxLetters = 31,
                onAccept = function(t) G:SetNote(name, t) end })
        end })
        if m.note ~= "" then tinsert(items, { text = "Clear public note", func = function() G:SetNote(name, "") end }) end
    end
    if G:CanOfficerNote() then
        tinsert(items, { text = "Officer note...", func = function()
            UI.Prompt({ title = "Officer note", text = name .. " (31 letters, officers only)", default = m.onote, maxLetters = 31,
                onAccept = function(t) G:SetNote(name, t, true) end })
        end })
        if (m.onote or "") ~= "" then tinsert(items, { text = "Clear officer note", func = function() G:SetNote(name, "", true) end }) end
    end
    local main = G:MainOf(name)
    if G:IsOfficer() or name == me() then
        tinsert(items, { text = "Alt of...", func = function()
            UI.Prompt({ title = "Link an alt", text = "Whose alt is " .. name .. "? (their main's name)", default = main ~= name and main or "",
                maxLetters = 12, accept = "Link", onAccept = function(t) G:LinkAlt(name, t) end })
        end })
    end
    if main ~= name and (G:IsOfficer() or name == me() or main == me()) then
        tinsert(items, { text = "Unlink from " .. main, func = function() G:UnlinkAlt(name) end })
    end
    tinsert(items, { text = "DKP: " .. G:Points(name) .. (main ~= name and (" (" .. main .. ")") or ""), disabled = true })
    UI.Menu(anchor, items)
end
G.MemberMenu = memberMenu

local function buildRoster(p)
    local r = { offline = true, sort = "rank" }
    r.search = box(p, "GuildHub_RosterSearch", 170, 40, "Search the roster", function() G:Render() end)
    r.search:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -30)
    r.offBtn = button(p, "Hide offline", 92, 18, function() r.offline = not r.offline; G:Render() end)
    r.offBtn:SetPoint("LEFT", r.search, "RIGHT", 6, 0)
    local SORTS = { rank = "level", level = "name", name = "rank" }
    r.sortBtn = button(p, "Sort: rank", 92, 18, function() r.sort = SORTS[r.sort]; G:Render() end)
    r.sortBtn:SetPoint("LEFT", r.offBtn, "RIGHT", 4, 0)
    r.export = button(p, "Export", 70, 18, function() G:ShowExport("Roster export", G:RosterExport()) end)
    r.export:SetPoint("LEFT", r.sortBtn, "RIGHT", 4, 0)
    r.count = label(p, 10, MUTED)
    r.count:SetPoint("TOPRIGHT", p, "TOPRIGHT", -2, -33)
    r.count:SetJustifyH("RIGHT")
    local well = inset(p, 0, -52, PAGE_W, 380)
    r.list = UI.ScrollList(well, { name = "GuildHub_RosterList", width = PAGE_W - 8, height = 372, rowHeight = 31,
        build = function(row, i)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            hl(row)
            row.name = UI.Label(row, 11, { 1, 1, 1 }, "OUTLINE")
            row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -3)
            row.rank = UI.Label(row, 10, UI.ACCENT)
            row.rank:SetPoint("TOPRIGHT", row, "TOPRIGHT", -54, -4)
            row.rank:SetJustifyH("RIGHT")
            row.info = UI.Label(row, 10, MUTED)
            row.info:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -17)
            row.info:SetWidth(PAGE_W - 76)
            row.up = arrow(row, "Up", function()
                local m = row.item
                return m and ("Promote to " .. rankName(m.rankIndex - 1)) or ""
            end, function() if row.item then G:Promote(row.item.name) end end)
            row.up:SetPoint("RIGHT", row, "RIGHT", -26, 0)
            row.down = arrow(row, "Down", function()
                local m = row.item
                return m and ("Demote to " .. rankName(m.rankIndex + 1)) or ""
            end, function() if row.item then G:Demote(row.item.name) end end)
            row.down:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row:SetScript("OnClick", function() memberMenu(row, row.item) end)
            setglobal("GuildHub_RosterRow" .. i, row)
        end,
        update = function(row, m)
            local main = G:MainOf(m.name)
            local alts = G:AltsOf(m.name)
            local tag = ""
            if main ~= m.name then tag = "  |cff9da3b4alt of " .. plain(main) .. "|r"
            elseif alts[1] then tag = "  |cff9da3b4+" .. getn(alts) .. " alt" .. (getn(alts) == 1 and "" or "s") .. "|r" end
            row.name:SetText(G.ColorName(m.name, m.token) .. "  |cffc8ccd6" .. m.level .. " " .. (G.CLASS_NAME[m.token or ""] or m.class or "") .. "|r" .. tag)
            row.rank:SetText(plain(m.rank))
            local bits = {}
            if m.online then tinsert(bits, "|cff60e070" .. (m.zone ~= "" and plain(m.zone) or "Online") .. "|r")
            else tinsert(bits, "|cff7a7d86Last online " .. G:LastOnline(m) .. "|r") end
            local prof = G:Professions(m.name)
            if not blank(prof) then tinsert(bits, plain(prof)) end
            if m.note ~= "" then tinsert(bits, "\"" .. plain(m.note) .. "\"") end
            if (m.onote or "") ~= "" and G:CanViewOfficerNote() then tinsert(bits, "|cffffa060[O] " .. plain(m.onote) .. "|r") end
            row.info:SetText(table.concat(bits, "  " .. DOT .. "  "))
            local officer = G:CanPromote() or G:CanDemote()
            show(row.up, officer)
            show(row.down, officer)
            if G:CanPromoteMember(m) then row.up:Enable() else row.up:Disable() end
            if G:CanDemoteMember(m) then row.down:Enable() else row.down:Disable() end
        end,
    })
    r.list:SetPoint("TOPLEFT", well, "TOPLEFT", 4, -4)
    return r
end

local function renderRoster(p)
    local r = ui.roster
    local items = G:RosterItems(r.search:GetText(), r.offline, r.sort)
    r.list:SetItems(items)
    local on = 0
    for _, m in ipairs(G.roster) do if m.online then on = on + 1 end end
    r.count:SetText(getn(items) .. " shown " .. DOT .. " " .. on .. " online")
    r.offBtn:SetText(r.offline and "Hide offline" or "Show offline")
    r.sortBtn:SetText("Sort: " .. r.sort)
    p.hint:SetText(G:IsOfficer() and "Click a member: notes, ranks, alts" or "Click a member for whisper, invite and alts")
end

-- -- Recruit ------------------------------------------------------------------------------------

local function concordForm() return Concord and Concord.ui and Concord.ui.form end

-- the Guilds board's "My listing" form lives in our page while it is shown
function G:EmbedListing(on)
    local form = concordForm()
    if not form then return end
    local page = ui.recruit.listing
    if on and not self.embedding then
        if Concord.board and Concord.board:IsShown() then Concord.board:Hide() end
        self.embedding = true
        Concord:ShowTab("mine")
        form:SetParent(page)
        form:ClearAllPoints()
        form:SetPoint("TOPLEFT", page, "TOPLEFT", floor((PAGE_W - 426) / 2), 0)
        form:SetWidth(426)
        form:SetHeight(420)
        form:Show()
        if Concord.PaintForm then Concord:PaintForm() end
    elseif not on and self.embedding then
        self.embedding = false
        form:SetParent(Concord.board.body)
        form:ClearAllPoints()
        form:SetAllPoints(Concord.board.body)
        Concord:ShowTab("Any")
    end
end

if Concord and Concord.ShowTab then
    local orig = Concord.ShowTab
    -- Post and Remove send the board back to its list; while embedded, keep the form up
    function Concord:ShowTab(key)
        orig(self, key)
        if G.embedding and key ~= "mine" then orig(self, "mine") end
    end
    if Concord.board then
        local onShow = Concord.board:GetScript("OnShow")
        Concord.board:SetScript("OnShow", function()
            if G.embedding then G:EmbedListing(false) end
            if onShow then onShow() end
        end)
    end
end

local APP_COLOR = { new = UI.ACCENT, accepted = GREEN, declined = RED }
local APP_WORD = { new = "New", accepted = "Invited", declined = "Declined" }

local function buildRecruit(p)
    local r = { filter = "new" }
    r.listing = CreateFrame("Frame", "GuildHub_Listing", p)
    r.listing:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -28)
    r.listing:SetWidth(PAGE_W)
    r.listing:SetHeight(424)
    r.noBoard = label(r.listing, 11, MUTED)
    r.noBoard:SetPoint("CENTER", r.listing, "CENTER", 0, 0)
    r.noBoard:SetText("Turn on Guilds in /addons to post your guild on the recruitment board.")
    r.listing:SetScript("OnShow", function() G:EmbedListing(true) end)
    r.listing:SetScript("OnHide", function() G:EmbedListing(false) end)
    if concordForm() then r.noBoard:Hide() end

    r.apps = CreateFrame("Frame", "GuildHub_Apps", p)
    r.apps:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -28)
    r.apps:SetWidth(PAGE_W)
    r.apps:SetHeight(424)
    local a = r.apps
    r.filters = {}
    local x = 0
    for _, f in ipairs({ { "new", "New" }, { "done", "Handled" }, { "all", "All" } }) do
        local key = f[1]
        local b = button(a, f[2], 74, 18, function() r.filter = key; G:Render() end)
        b:SetPoint("TOPLEFT", a, "TOPLEFT", x, -2)
        x = x + 78
        r.filters[key] = b
    end
    r.count = label(a, 10, MUTED)
    r.count:SetPoint("TOPRIGHT", a, "TOPRIGHT", -2, -5)
    r.count:SetJustifyH("RIGHT")
    r.well = inset(a, 0, -24, PAGE_W, 380)
    r.list = UI.ScrollList(r.well, { name = "GuildHub_AppList", width = PAGE_W - 8, height = 372, rowHeight = 62,
        build = function(row, i)
            hl(row)
            row.name = UI.Label(row, 11, { 1, 1, 1 }, "OUTLINE")
            row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
            row.when = UI.Label(row, 10, MUTED)
            row.when:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -5)
            row.when:SetJustifyH("RIGHT")
            row.text = UI.Label(row, 10, TEXT)
            row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -19)
            row.text:SetWidth(PAGE_W - 30)
            row.note = UI.Label(row, 10, { 1, 0.75, 0.45 })
            row.note:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -32)
            row.note:SetWidth(PAGE_W - 250)
            local function act(fn) return function() if row.item then fn(row.item.id) end end end
            row.whisper = button(row, "Whisper", 62, 16, act(function(id)
                if ChatFrame_OpenChat then ChatFrame_OpenChat("/w " .. G.GDB().ap[id].name .. " ") end
            end))
            row.whisper:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 5)
            row.noteBtn = button(row, "Note", 50, 16, act(function(id)
                UI.Prompt({ title = "Note", text = "A note on " .. G.GDB().ap[id].name .. " (officers see it)", default = G.GDB().ap[id].note,
                    maxLetters = 120, onAccept = function(t) G:NoteApp(id, t) end })
            end))
            row.noteBtn:SetPoint("RIGHT", row.whisper, "LEFT", -3, 0)
            row.decline = button(row, "Decline", 62, 16, act(function(id) G:DeclineApp(id) end))
            row.decline:SetPoint("RIGHT", row.noteBtn, "LEFT", -3, 0)
            row.accept = button(row, "Accept", 62, 16, act(function(id) G:AcceptApp(id) end))
            row.accept:SetPoint("RIGHT", row.decline, "LEFT", -3, 0)
            setglobal("GuildHub_AppRow" .. i, row)
        end,
        update = function(row, ap)
            local token = G.Token(ap.class)
            local c = APP_COLOR[ap.st] or MUTED
            row.name:SetText(G.ColorName(ap.name, token) .. "  |cffc8ccd6" .. (ap.level and ("level " .. ap.level .. " ") or "")
                .. (G.CLASS_NAME[token or ""] or plain(ap.class or "")) .. "|r  " .. string.format("|cff%02x%02x%02x", floor(c[1] * 255), floor(c[2] * 255), floor(c[3] * 255))
                .. (APP_WORD[ap.st] or plain(ap.st or "")) .. "|r")
            row.when:SetText((G.Ago(ap.t) or "") .. (ap.by and ap.by ~= "" and ap.st ~= "new" and (" " .. DOT .. " " .. plain(ap.by)) or ""))
            row.text:SetText("\"" .. plain(ap.text or "") .. "\"")
            row.note:SetText(blank(ap.note) and "" or ("Note: " .. plain(ap.note)))
            if ap.st == "new" and G:CanInvite() then row.accept:Enable() else row.accept:Disable() end
            if ap.st == "new" then row.decline:Enable() else row.decline:Disable() end
        end,
    })
    r.list:SetPoint("TOPLEFT", r.well, "TOPLEFT", 4, -4)
    r.empty = label(r.well, 11, MUTED)
    r.empty:SetPoint("CENTER", r.well, "CENTER", 0, 0)
    r.empty:SetWidth(PAGE_W - 80)
    r.empty:SetJustifyH("CENTER")
    r.foot = label(a, 10, MUTED, 2, -410, PAGE_W - 4)
    r.foot:SetText("Applications are the whispers players send from the Guilds board's Apply button.")
    return r
end

local function renderRecruit(p, sub)
    local r = ui.recruit
    show(r.listing, sub == "listing")
    show(r.apps, sub == "apps")
    p.hint:SetText(sub == "listing" and "Your guild's card on the Guilds board" or "Accept invites them to the guild")
    if sub ~= "apps" then return end
    local officer = G:CanInvite() or G:IsOfficer()
    for k, b in pairs(r.filters) do if k == r.filter then b:LockHighlight() else b:UnlockHighlight() end end
    if not officer then
        r.list:SetItems({})
        r.count:SetText("")
        r.empty:SetText("Applications reach the guild's officers.\nAsk one to post your guild on the Guilds board.")
        r.empty:Show()
        return
    end
    local items = G:Applications(r.filter)
    r.list:SetItems(items)
    local waiting = getn(G:Applications("new"))
    r.count:SetText(waiting .. " waiting")
    show(r.empty, not items[1])
    r.empty:SetText(r.filter == "new" and "No applications waiting.\nPost your guild on the Listing tab and they arrive here." or "Nothing here yet.")
end

-- -- Events -------------------------------------------------------------------------------------

local DAY_W = floor((PAGE_W - 8) / 7)
local SLOTS = 5
G.week = 0

function G:SelectEvent(id)
    self.selected = id
    self.newEvent = false
    self.dirty = true
end

local ROLE_ICON = {
    t = { "Dungeons_Tank", "Interface\\Icons\\Ability_Warrior_DefensiveStance" },
    h = { "Dungeons_Healer", "Interface\\Icons\\Spell_Holy_FlashHeal" },
    d = { "Dungeons_Damage", "Interface\\Icons\\INV_Sword_04" },
}

local function buildEvents(p)
    local e = {}
    e.prev = button(p, "<", 24, 18, function() G.week = G.week - 1; G:Render() end)
    e.prev:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -30)
    e.today = button(p, "This week", 80, 18, function() G.week = 0; G:Render() end)
    e.today:SetPoint("LEFT", e.prev, "RIGHT", 3, 0)
    e.next = button(p, ">", 24, 18, function() G.week = G.week + 1; G:Render() end)
    e.next:SetPoint("LEFT", e.today, "RIGHT", 3, 0)
    e.range = UI.Label(p, 11, UI.ACCENT)
    e.range:SetPoint("LEFT", e.next, "RIGHT", 10, 0)
    e.new = button(p, "New event", 90, 18, function()
        G.newEvent = not G.newEvent
        if G.newEvent and not G.formDay then G.formDay = G.DayStart(now()) end
        G:Render()
    end)
    e.new:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, -30)

    local grid = inset(p, 0, -52, PAGE_W, 198)
    e.days = {}
    for d = 1, 7 do
        local col = {}
        local x = 4 + (d - 1) * DAY_W
        col.head = CreateFrame("Button", "GuildHub_Day" .. d, grid)
        col.head:SetWidth(DAY_W - 2)
        col.head:SetHeight(18)
        col.head:SetPoint("TOPLEFT", grid, "TOPLEFT", x, -4)
        col.head.bg = col.head:CreateTexture(nil, "BACKGROUND")
        col.head.bg:SetAllPoints(col.head)
        col.head.text = UI.Label(col.head, 10, TEXT, "OUTLINE")
        col.head.text:SetPoint("CENTER", col.head, "CENTER", 0, 0)
        col.head.text:SetJustifyH("CENTER")
        hl(col.head)
        local idx = d
        col.head:SetScript("OnClick", function()
            G.formDay = G.WeekStart(G.week) + (idx - 1) * 86400 + 3600 * 2   -- DST-safe: noon-ish then floor
            G.formDay = G.DayStart(G.formDay)
            if G:IsOfficer() then G.newEvent = true end
            G:Render()
        end)
        col.slots = {}
        for s = 1, SLOTS do
            local b = CreateFrame("Button", "GuildHub_Day" .. d .. "Event" .. s, grid)
            b:SetWidth(DAY_W - 4)
            b:SetHeight(32)
            b:SetPoint("TOPLEFT", grid, "TOPLEFT", x + 1, -24 - (s - 1) * 34)
            b:SetBackdrop(UI.THIN)
            b.time = UI.Label(b, 10, UI.ACCENT)
            b.time:SetPoint("TOPLEFT", b, "TOPLEFT", 5, -4)
            b.title = UI.Label(b, 10, { 1, 1, 1 })
            b.title:SetPoint("TOPLEFT", b, "TOPLEFT", 5, -16)
            b.title:SetWidth(DAY_W - 12)
            if b.title.SetNonSpaceWrap then b.title:SetNonSpaceWrap(false) end
            b.title:SetHeight(12)
            hl(b)
            b:SetScript("OnClick", function() if b.event then G:SelectEvent(b.event.id) end end)
            b:SetScript("OnEnter", function()
                local ev = b.event
                if not ev then return end
                GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
                GameTooltip:SetText(plain(ev.title), 1, 0.82, 0)
                GameTooltip:AddLine(G.EventTime(ev), 1, 1, 1)
                if not blank(ev.note) then GameTooltip:AddLine(plain(ev.note), 0.8, 0.8, 0.8, 1) end
                local c = G:SignupCounts(ev.id)
                GameTooltip:AddLine(c.yes .. " signed up (" .. c.t .. " tank, " .. c.h .. " heal, " .. c.d .. " dps), " .. c.tent .. " tentative", 0.6, 0.85, 1)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            b:Hide()
            col.slots[s] = b
        end
        e.days[d] = col
    end

    -- details of the picked event, or the new-event form
    local det = inset(p, 0, -254, PAGE_W, 176)
    e.det = det
    e.dtitle = UI.Label(det, 13, UI.ACCENT, "OUTLINE")
    e.dtitle:SetPoint("TOPLEFT", det, "TOPLEFT", 10, -8)
    e.dtime = label(det, 10, { 1, 1, 1 }, 10, -26)
    e.dnote = label(det, 10, MUTED, 10, -40, PAGE_W - 20)
    e.dcount = label(det, 10, BLUE, 10, -56, PAGE_W - 20)
    e.dmine = label(det, 10, TEXT)
    e.dmine:SetPoint("TOPRIGHT", det, "TOPRIGHT", -10, -26)
    e.dmine:SetJustifyH("RIGHT")
    e.sign = {}
    local x = 10
    for _, s in ipairs({ { "t", "yes", "Tank" }, { "h", "yes", "Healer" }, { "d", "yes", "Damage" }, { "d", "tent", "Tentative" }, { "d", "no", "Decline" } }) do
        local role, st = s[1], s[2]
        local b = button(det, s[3], 80, 18, function()
            if not G.selected then return end
            if st ~= "yes" then
                local mine = G:MySignup(G.selected)
                role = (mine and mine.role) or (Social and Social.RoleOf and Social.RoleOf(me())) or "d"
            end
            G:SignUp(G.selected, role, st)
        end)
        b:SetPoint("TOPLEFT", det, "TOPLEFT", x, -74)
        x = x + 84
        tinsert(e.sign, b)
    end
    e.post = button(det, "Post to guild", 96, 18, function() if G.selected then G:PostEvent(G.selected, "GUILD") end end)
    e.post:SetPoint("TOPRIGHT", det, "TOPRIGHT", -10, -6)
    e.del = button(det, "Delete", 64, 18, function()
        if G.selected then G:DeleteEvent(G.selected); G.selected = nil end
    end)
    e.del:SetPoint("RIGHT", e.post, "LEFT", -4, 0)
    e.who = label(det, 10, TEXT, 10, -100, PAGE_W - 20)
    e.who:SetHeight(70)
    if e.who.SetJustifyV then e.who:SetJustifyV("TOP") end
    e.empty = label(det, 11, MUTED)
    e.empty:SetPoint("CENTER", det, "CENTER", 0, 0)
    e.empty:SetJustifyH("CENTER")

    -- new event form (officers)
    local f = CreateFrame("Frame", "GuildHub_EventForm", det)
    f:SetAllPoints(det)
    f:Hide()
    e.form = f
    local ft = UI.Label(f, 12, UI.ACCENT, "OUTLINE")
    ft:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -8)
    ft:SetText("New event")
    e.fday = label(f, 11, { 1, 1, 1 })
    e.fday:SetPoint("LEFT", ft, "RIGHT", 12, 0)
    local lt = label(f, 10, MUTED, 10, -34) lt:SetText("Title")
    e.ftitle = box(f, "GuildHub_EventTitle", 230, 40, "Molten Core, guild meeting...")
    e.ftitle:SetPoint("TOPLEFT", f, "TOPLEFT", 70, -30)
    local lh = label(f, 10, MUTED, 316, -34) lh:SetText("Time")
    e.ftime = box(f, "GuildHub_EventTime", 52, 5, "20:00")
    e.ftime:SetPoint("TOPLEFT", f, "TOPLEFT", 350, -30)
    local ld = label(f, 10, MUTED, 414, -34) ld:SetText("Hours")
    e.fdur = box(f, "GuildHub_EventHours", 36, 4, "2")
    e.fdur:SetPoint("TOPLEFT", f, "TOPLEFT", 456, -30)
    local ln = label(f, 10, MUTED, 10, -60) ln:SetText("Note")
    e.fnote = box(f, "GuildHub_EventNote", PAGE_W - 90, 120, "Bring fire resistance; sign up by Tuesday")
    e.fnote:SetPoint("TOPLEFT", f, "TOPLEFT", 70, -56)
    e.fhint = label(f, 10, MUTED, 10, -88, PAGE_W - 20)
    e.fhint:SetText("Click a day above to pick the date. Times are your clock (realm time on the official realm).")
    e.create = button(f, "Create", 90, 20, function()
        local _, _, hh, mm = strfind(e.ftime:GetText() or "", "^%s*(%d%d?):?(%d%d)%s*$")
        if not hh then _, _, hh = strfind(e.ftime:GetText() or "", "^%s*(%d%d?)%s*$") mm = 0 end
        hh, mm = tonumber(hh), tonumber(mm)
        if not hh or hh > 23 or mm > 59 then W.Print("Guild Hub: the time is HH:MM, like 20:00.") return end
        local d = date("*t", G.formDay or G.DayStart(now()))
        local start = time({ year = d.year, month = d.month, day = d.day, hour = hh, min = mm, sec = 0 })
        local hours = tonumber(e.fdur:GetText()) or 2
        local id = G:CreateEvent(e.ftitle:GetText(), start, floor(hours * 60), e.fnote:GetText())
        if id then
            e.ftitle:SetText(""); e.fnote:SetText("")
            G:SelectEvent(id)
        else
            W.Print("Guild Hub: give the event a title.")
        end
    end)
    e.create:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 10)
    e.cancel = button(f, "Cancel", 90, 20, function() G.newEvent = false; G:Render() end)
    e.cancel:SetPoint("LEFT", e.create, "RIGHT", 6, 0)
    return e
end

local function whoLine(list, st, role)
    local out = {}
    for _, s in ipairs(list) do
        if s.st == st and (not role or s.role == role) then tinsert(out, G.ColorName(s.name, memberToken(s.name))) end
    end
    return out
end

local function renderEvents(p)
    local e = ui.events
    local officer = G:IsOfficer()
    show(e.new, officer)
    p.hint:SetText(officer and "Click a day to add an event there" or "Click an event to sign up")
    local start = G.WeekStart(G.week)
    e.range:SetText(date("%d %b", start) .. " - " .. date("%d %b", start + 6 * 86400 + 3600))
    local today = G.DayStart(now())
    local list = G:EventsBetween(start, start + 7 * 86400 + 3600)
    for d = 1, 7 do
        local col = e.days[d]
        local day0 = G.DayStart(start + (d - 1) * 86400 + 7200)
        local day1 = G.DayStart(day0 + 86400 + 7200)
        local evs = {}
        for _, ev in ipairs(list) do if ev.start >= day0 and ev.start < day1 then tinsert(evs, ev) end end
        local extra = getn(evs) - SLOTS
        col.head.text:SetText(date("%a %d", day0) .. (extra > 0 and (" +" .. extra) or ""))
        if day0 == today then col.head.bg:SetTexture(0.35, 0.26, 0.06, 0.9) col.head.text:SetTextColor(1, 0.85, 0.3)
        elseif G.newEvent and G.formDay == day0 then col.head.bg:SetTexture(0.15, 0.25, 0.4, 0.9) col.head.text:SetTextColor(1, 1, 1)
        else col.head.bg:SetTexture(0.08, 0.08, 0.1, 0.8) col.head.text:SetTextColor(TEXT[1], TEXT[2], TEXT[3]) end
        for s = 1, SLOTS do
            local b, ev = col.slots[s], evs[s]
            b.event = ev
            if ev then
                local mine = G:MySignup(ev.id)
                b.time:SetText(date("%H:%M", ev.start) .. (mine and mine.st == "yes" and "  |cff60e070" .. "\226\156\148|r" or ""))
                b.title:SetText(plain(ev.title))
                local past = ev.start + (ev.dur or 120) * 60 < now()
                local sel = (ev.id == G.selected)
                b:SetBackdropColor(sel and 0.22 or 0.10, sel and 0.18 or 0.12, sel and 0.06 or 0.16, past and 0.5 or 0.95)
                if sel then b:SetBackdropBorderColor(1, 0.82, 0, 1) else b:SetBackdropBorderColor(0.4, 0.42, 0.5, 1) end
                b:SetAlpha(past and 0.6 or 1)
                b:Show()
            else
                b:Hide()
            end
        end
    end
    -- details / form
    local ev = G.selected and G.GDB().ev[G.selected]
    if ev and (ev.del or 0) == 1 then ev = nil; G.selected = nil end
    local form = G.newEvent and officer
    show(e.form, form)
    local detail = (not form) and ev
    for _, x in ipairs({ e.dtitle, e.dtime, e.dnote, e.dcount, e.dmine, e.who }) do show(x, detail) end
    for _, b in ipairs(e.sign) do show(b, detail) end
    show(e.post, detail)
    show(e.del, detail and officer)
    show(e.empty, not form and not ev)
    e.empty:SetText(officer and "Pick an event above, or click a day (or New event) to add one." or "Pick an event above to see who is going and sign up.")
    if form then
        e.fday:SetText(date("%A %d %B", G.formDay or now()))
        return
    end
    if not ev then return end
    e.dtitle:SetText(plain(ev.title))
    local hours = floor((ev.dur or 120) / 60 * 10 + 0.5) / 10
    e.dtime:SetText(G.EventTime(ev) .. "  " .. DOT .. "  " .. hours .. " h  " .. DOT .. "  by " .. plain(ev.by or "?"))
    e.dnote:SetText(plain(ev.note or ""))
    local c = G:SignupCounts(ev.id)
    e.dcount:SetText(c.yes .. " going: " .. c.t .. " tank" .. (c.t == 1 and "" or "s") .. ", " .. c.h .. " healer" .. (c.h == 1 and "" or "s")
        .. ", " .. c.d .. " damage  " .. DOT .. "  " .. c.tent .. " tentative  " .. DOT .. "  " .. c.no .. " declined")
    local mine = G:MySignup(ev.id)
    if mine then
        e.dmine:SetText("You: " .. (mine.st == "yes" and ("|cff60e070" .. G.ROLE_LABEL[mine.role or "d"] .. "|r")
            or mine.st == "tent" and "|cffffd100tentative|r" or "|cffff6a60declined|r"))
    else
        e.dmine:SetText("|cff9da3b4You haven't signed up|r")
    end
    local su = G:Signups(ev.id)
    local lines = {}
    for _, r in ipairs({ { "t", "Tanks" }, { "h", "Healers" }, { "d", "Damage" } }) do
        local names = whoLine(su, "yes", r[1])
        if names[1] then tinsert(lines, "|cffffd100" .. r[2] .. ":|r " .. table.concat(names, ", ")) end
    end
    local tent, no = whoLine(su, "tent"), whoLine(su, "no")
    if tent[1] then tinsert(lines, "|cffffd100Tentative:|r " .. table.concat(tent, ", ")) end
    if no[1] then tinsert(lines, "|cff9da3b4Declined:|r " .. table.concat(no, ", ")) end
    e.who:SetText(lines[1] and table.concat(lines, "\n") or "|cff9da3b4Nobody has signed up yet.|r")
end

-- -- Bank ---------------------------------------------------------------------------------------

local function buildBank(p)
    local b = { kind = "dep", showDone = false }
    b.log = CreateFrame("Frame", "GuildHub_BankLog", p)
    b.log:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -28)
    b.log:SetWidth(PAGE_W)
    b.log:SetHeight(424)
    local l = b.log
    b.balance = UI.Label(l, 12, UI.ACCENT, "OUTLINE")
    b.balance:SetPoint("TOPLEFT", l, "TOPLEFT", 2, -4)
    b.purse = label(l, 10, MUTED)
    b.purse:SetPoint("TOPRIGHT", l, "TOPRIGHT", -2, -5)
    b.purse:SetJustifyH("RIGHT")
    -- manual entry (officers)
    b.form = CreateFrame("Frame", nil, l)
    b.form:SetPoint("TOPLEFT", l, "TOPLEFT", 0, -22)
    b.form:SetWidth(PAGE_W)
    b.form:SetHeight(22)
    b.kindBtn = button(b.form, "Deposit", 84, 18, function() b.kind = (b.kind == "dep") and "wd" or "dep"; G:Render() end)
    b.kindBtn:SetPoint("TOPLEFT", b.form, "TOPLEFT", 0, 0)
    b.who = box(b.form, "GuildHub_BankWho", 84, 12, "Who")
    b.who:SetPoint("LEFT", b.kindBtn, "RIGHT", 4, 0)
    b.amount = box(b.form, "GuildHub_BankAmount", 80, 16, "12g 50s")
    b.amount:SetPoint("LEFT", b.who, "RIGHT", 4, 0)
    b.item = box(b.form, "GuildHub_BankItem", 150, 60, "Item (optional)")
    b.item:SetPoint("LEFT", b.amount, "RIGHT", 4, 0)
    b.count = box(b.form, "GuildHub_BankCount", 34, 4, "1")
    b.count:SetPoint("LEFT", b.item, "RIGHT", 4, 0)
    b.count:SetNumeric(true)
    b.add = button(b.form, "Add", 60, 18, function()
        local copper = G.ParseMoney(b.amount:GetText()) or 0
        local item = W.Trim(b.item:GetText() or "")
        if G:BankAdd(b.kind, blank(b.who:GetText()) and me() or b.who:GetText(), copper, item, tonumber(b.count:GetText()), nil, false) then
            b.amount:SetText(""); b.item:SetText(""); b.count:SetText(""); b.who:SetText("")
        else
            W.Print("Guild Hub: enter an amount (12g 50s) or an item.")
        end
    end)
    b.add:SetPoint("LEFT", b.count, "RIGHT", 4, 0)
    b.memberHint = label(l, 10, MUTED, 2, -26, PAGE_W - 4)
    b.well = inset(l, 0, -48, PAGE_W, 360)
    b.list = UI.ScrollList(b.well, { name = "GuildHub_BankList", width = PAGE_W - 8, height = 352, rowHeight = 22,
        build = function(row, i)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            hl(row)
            row.date = label(row, 10, MUTED)
            row.date:SetPoint("LEFT", row, "LEFT", 6, 0)
            row.what = label(row, 10, TEXT)
            row.what:SetPoint("LEFT", row, "LEFT", 96, 0)
            row.what:SetWidth(230)
            row.who = label(row, 10, TEXT)
            row.who:SetPoint("LEFT", row, "LEFT", 330, 0)
            row.who:SetWidth(130)
            row.bal = label(row, 10, UI.ACCENT)
            row.bal:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            row.bal:SetJustifyH("RIGHT")
            row:SetScript("OnClick", function()
                local x = row.item
                if not x or not G:IsOfficer() then return end
                UI.Menu(row, { { text = date("%d %b %H:%M", x.t or 0), title = true },
                    { text = (x.void or 0) == 1 and "Already void" or "Void this entry", disabled = (x.void or 0) == 1,
                        color = { 1, 0.45, 0.4 }, func = function() G:BankVoid(x.id) end } })
            end)
            setglobal("GuildHub_BankRow" .. i, row)
        end,
        update = function(row, x)
            local void = (x.void or 0) == 1
            row.date:SetText(date("%d %b %H:%M", x.t or 0))
            local sign = x.kind == "dep" and "+" or "-"
            local col = void and "|cff6a6d76" or (x.kind == "dep" and "|cff60e070" or "|cffff6a60")
            local what = {}
            if (x.copper or 0) > 0 then tinsert(what, sign .. G.Money(x.copper)) end
            if not blank(x.item) then tinsert(what, sign .. ((x.count or 1) > 1 and (x.count .. " x ") or "") .. plain(x.item)) end
            row.what:SetText(col .. table.concat(what, ", ") .. "|r" .. (void and " |cff6a6d76(void)|r" or ""))
            row.who:SetText((x.kind == "dep" and "from " or "to ") .. plain(x.who or "?") .. ((x.auto or 0) == 1 and " |cff9da3b4(trade)|r" or ""))
            row.bal:SetText(G.Money(x.balance or 0))
        end,
    })
    b.list:SetPoint("TOPLEFT", b.well, "TOPLEFT", 4, -4)
    b.empty = label(b.well, 11, MUTED)
    b.empty:SetPoint("CENTER", b.well, "CENTER", 0, 0)
    b.empty:SetWidth(PAGE_W - 80)
    b.empty:SetJustifyH("CENTER")

    -- requests
    b.reqs = CreateFrame("Frame", "GuildHub_BankRequests", p)
    b.reqs:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -28)
    b.reqs:SetWidth(PAGE_W)
    b.reqs:SetHeight(424)
    local q = b.reqs
    b.ask = box(q, "GuildHub_RequestText", PAGE_W - 200, 160, "What do you need? (20 Elemental Fire, a Lionheart Helm...)")
    b.ask:SetPoint("TOPLEFT", q, "TOPLEFT", 0, -2)
    b.askBtn = button(q, "Ask the bank", 96, 18, function()
        if G:Request(b.ask:GetText()) then b.ask:SetText("") end
    end)
    b.askBtn:SetPoint("LEFT", b.ask, "RIGHT", 4, 0)
    b.doneBtn = button(q, "Show done", 90, 18, function() b.showDone = not b.showDone; G:Render() end)
    b.doneBtn:SetPoint("TOPRIGHT", q, "TOPRIGHT", 0, -2)
    b.rwell = inset(q, 0, -24, PAGE_W, 384)
    b.rlist = UI.ScrollList(b.rwell, { name = "GuildHub_RequestList", width = PAGE_W - 8, height = 376, rowHeight = 32,
        build = function(row, i)
            hl(row)
            row.who = UI.Label(row, 11, { 1, 1, 1 }, "OUTLINE")
            row.who:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -3)
            row.text = label(row, 10, TEXT)
            row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -17)
            row.text:SetWidth(PAGE_W - 170)
            row.decline = button(row, "Decline", 62, 18, function() if row.item then G:ResolveRequest(row.item.id, "declined") end end)
            row.decline:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.done = button(row, "Done", 56, 18, function() if row.item then G:ResolveRequest(row.item.id, "done") end end)
            row.done:SetPoint("RIGHT", row.decline, "LEFT", -3, 0)
            setglobal("GuildHub_RequestRow" .. i, row)
        end,
        update = function(row, r)
            local st = r.st == "open" and "|cffffd100open|r" or r.st == "done" and "|cff60e070done|r" or "|cffff6a60declined|r"
            row.who:SetText(G.ColorName(r.who or "?", memberToken(r.who)) .. "  |cff9da3b4" .. (G.Ago(r.t) or "") .. "|r  " .. st
                .. (r.st ~= "open" and r.by and (" |cff9da3b4by " .. plain(r.by) .. "|r") or ""))
            row.text:SetText(plain(r.text or ""))
            local can = G:IsOfficer() and r.st == "open"
            show(row.done, can)
            show(row.decline, can)
        end,
    })
    b.rlist:SetPoint("TOPLEFT", b.rwell, "TOPLEFT", 4, -4)
    b.rempty = label(b.rwell, 11, MUTED)
    b.rempty:SetPoint("CENTER", b.rwell, "CENTER", 0, 0)
    b.rempty:SetText("No open requests.")
    return b
end

local function renderBank(p, sub)
    local b = ui.bank
    show(b.log, sub == "log")
    show(b.reqs, sub == "requests")
    local banker = G:Banker()
    p.hint:SetText(banker and ("Banker: " .. plain(banker)) or "No banker set (Guild > Setup)")
    if sub == "requests" then
        local items = G:Requests(b.showDone)
        b.rlist:SetItems(items)
        b.doneBtn:SetText(b.showDone and "Hide done" or "Show done")
        show(b.rempty, not items[1])
        return
    end
    local log, bal = G:BankLog()
    b.list:SetItems(log)
    b.balance:SetText("Balance by the log: " .. G.Money(bal))
    local purse = G:Purse()
    b.purse:SetText(purse and (plain(purse.who or "?") .. " holds " .. G.Money(purse.copper) .. " (" .. (G.Ago(purse.u) or "") .. ")") or "")
    local officer = G:IsOfficer()
    show(b.form, officer)
    show(b.memberHint, not officer)
    b.memberHint:SetText(banker and ("Trade gold or items with " .. plain(banker) .. " and the trade logs itself here.")
        or "An officer picks the guild's banker character in Guild > Setup.")
    b.kindBtn:SetText(b.kind == "dep" and "Deposit" or "Withdrawal")
    show(b.empty, not log[1])
    b.empty:SetText(banker and ("Nothing logged yet. Trades with " .. plain(banker) .. " appear here by themselves.")
        or "No banker set. Officers: Guild > Setup.")
end

-- -- DKP ----------------------------------------------------------------------------------------

local function sub(p, name)
    local f = CreateFrame("Frame", name, p)
    f:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -28)
    f:SetWidth(PAGE_W)
    f:SetHeight(424)
    return f
end

local function buildDKP(p)
    local d = {}
    -- standings
    d.standings = sub(p, "GuildHub_DKPStandings")
    local s = d.standings
    d.tick = button(s, "Tick raid", 80, 18, function()
        if not G:TickRaid("Attendance") then W.Print("Guild Hub: join a raid to tick its members.") end
    end)
    d.tick:SetPoint("TOPLEFT", s, "TOPLEFT", 0, -2)
    d.export = button(s, "Export", 70, 18, function() G:ShowExport("DKP standings", G:DKPExport(false)) end)
    d.export:SetPoint("LEFT", d.tick, "RIGHT", 4, 0)
    d.count = label(s, 10, MUTED)
    d.count:SetPoint("TOPRIGHT", s, "TOPRIGHT", -2, -5)
    d.count:SetJustifyH("RIGHT")
    d.award = CreateFrame("Frame", nil, s)
    d.award:SetPoint("TOPLEFT", s, "TOPLEFT", 0, -24)
    d.award:SetWidth(PAGE_W)
    d.award:SetHeight(20)
    d.names = box(d.award, "GuildHub_DKPNames", 240, 200, "Names, comma separated")
    d.names:SetPoint("TOPLEFT", d.award, "TOPLEFT", 0, 0)
    d.amt = box(d.award, "GuildHub_DKPAmount", 50, 6, "+10")
    d.amt:SetPoint("LEFT", d.names, "RIGHT", 4, 0)
    d.reason = box(d.award, "GuildHub_DKPReason", 170, 60, "Reason")
    d.reason:SetPoint("LEFT", d.amt, "RIGHT", 4, 0)
    d.awardBtn = button(d.award, "Award", 70, 18, function()
        local names = {}
        for _, n in ipairs(G.SplitList(strgsub(d.names:GetText() or "", "%s", ""), ",")) do tinsert(names, n) end
        local amt = tonumber(d.amt:GetText())
        if G:AddDKP(amt and amt < 0 and "adjust" or "award", names, amt, d.reason:GetText()) then
            d.names:SetText(""); d.amt:SetText(""); d.reason:SetText("")
        else
            W.Print("Guild Hub: names and a number of points, please.")
        end
    end)
    d.awardBtn:SetPoint("LEFT", d.reason, "RIGHT", 4, 0)
    d.well = inset(s, 0, -48, PAGE_W, 376)
    d.list = UI.ScrollList(d.well, { name = "GuildHub_DKPList", width = PAGE_W - 8, height = 368, rowHeight = 20,
        build = function(row, i)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            hl(row)
            row.pos = label(row, 10, MUTED)
            row.pos:SetPoint("LEFT", row, "LEFT", 6, 0)
            row.name = UI.Label(row, 11, { 1, 1, 1 }, "OUTLINE")
            row.name:SetPoint("LEFT", row, "LEFT", 34, 0)
            row.pts = UI.Label(row, 12, UI.ACCENT, "OUTLINE")
            row.pts:SetPoint("RIGHT", row, "LEFT", 270, 0)
            row.pts:SetJustifyH("RIGHT")
            row.info = label(row, 10, MUTED)
            row.info:SetPoint("LEFT", row, "LEFT", 290, 0)
            row:SetScript("OnClick", function() local m = row.item and G:Member(row.item.name) if m then memberMenu(row, m) end end)
            setglobal("GuildHub_DKPRow" .. i, row)
        end,
        update = function(row, r, i)
            row.pos:SetText(i .. ".")
            local alts = G:AltsOf(r.name)
            row.name:SetText(G.ColorName(r.name, memberToken(r.name)) .. (alts[1] and ("  |cff9da3b4+" .. table.concat(alts, ", ") .. "|r") or ""))
            row.pts:SetText(r.pts)
            row.info:SetText("+" .. r.earned .. " / -" .. r.spent .. "  " .. DOT .. "  " .. r.ticks .. " tick" .. (r.ticks == 1 and "" or "s")
                .. "  " .. DOT .. "  " .. r.items .. " item" .. (r.items == 1 and "" or "s"))
        end,
    })
    d.list:SetPoint("TOPLEFT", d.well, "TOPLEFT", 4, -4)
    d.empty = label(d.well, 11, MUTED)
    d.empty:SetPoint("CENTER", d.well, "CENTER", 0, 0)
    d.empty:SetText("No DKP yet. Boss kills tick the raid by themselves when an officer is there.")

    -- loot
    d.loot = sub(p, "GuildHub_DKPLoot")
    local l = d.loot
    d.lwin = box(l, "GuildHub_LootWinner", 100, 12, "Winner")
    d.lwin:SetPoint("TOPLEFT", l, "TOPLEFT", 0, -2)
    d.litem = box(l, "GuildHub_LootItem", 230, 60, "Item")
    d.litem:SetPoint("LEFT", d.lwin, "RIGHT", 4, 0)
    d.lcost = box(l, "GuildHub_LootCost", 50, 6, "Cost")
    d.lcost:SetPoint("LEFT", d.litem, "RIGHT", 4, 0)
    d.lbtn = button(l, "Award loot", 90, 18, function()
        if G:AwardLoot(d.lwin:GetText(), d.litem:GetText(), tonumber(d.lcost:GetText()) or 0) then
            d.lwin:SetText(""); d.litem:SetText(""); d.lcost:SetText("")
        else
            W.Print("Guild Hub: a winner and an item, please.")
        end
    end)
    d.lbtn:SetPoint("LEFT", d.lcost, "RIGHT", 4, 0)
    d.lhint = label(l, 10, MUTED, 2, -6, PAGE_W - 4)
    d.lwell = inset(l, 0, -24, PAGE_W, 400)

    -- history (also used for loot, filtered)
    local function entryList(parent, name)
        return UI.ScrollList(parent, { name = name, width = PAGE_W - 8, height = 392, rowHeight = 20,
            build = function(row, i)
                row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                hl(row)
                row.date = label(row, 10, MUTED)
                row.date:SetPoint("LEFT", row, "LEFT", 6, 0)
                row.text = label(row, 10, TEXT)
                row.text:SetPoint("LEFT", row, "LEFT", 92, 0)
                row.text:SetWidth(PAGE_W - 170)
                row.amt = UI.Label(row, 11, UI.ACCENT, "OUTLINE")
                row.amt:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                row.amt:SetJustifyH("RIGHT")
                row:SetScript("OnClick", function()
                    local x = row.item
                    if not x or not G:IsOfficer() then return end
                    UI.Menu(row, { { text = (x.reason or x.kind or "") .. " " .. date("%d %b", x.t or 0), title = true },
                        { text = (x.void or 0) == 1 and "Already void" or "Void this entry", disabled = (x.void or 0) == 1,
                            color = { 1, 0.45, 0.4 }, func = function() G:VoidDKP(x.id) end } })
                end)
                setglobal(name .. "Row" .. i, row)
            end,
            update = function(row, x)
                local void = (x.void or 0) == 1
                row.date:SetText(date("%d %b %H:%M", x.t or 0))
                local names = G.SplitList(x.names, ":")
                local who = getn(names) > 4 and (getn(names) .. " players") or table.concat(names, ", ")
                local what
                if x.kind == "loot" then what = plain(who) .. " won " .. plain(x.item or "?")
                elseif x.kind == "tick" then what = "Raid tick: " .. plain(x.reason or "") .. " (" .. getn(names) .. " players)"
                else what = plain(who) .. (blank(x.reason) and "" or (" - " .. plain(x.reason))) end
                row.text:SetText((void and "|cff6a6d76" or "") .. what .. " |cff9da3b4by " .. plain(x.by or "?") .. "|r" .. (void and " (void)|r" or ""))
                local amt = x.amt or 0
                if x.kind == "loot" then amt = -amt end
                row.amt:SetText(void and "|cff6a6d76-|r" or ((amt >= 0 and "+" or "") .. amt))
            end,
        })
    end
    d.llist = entryList(d.lwell, "GuildHub_LootList")
    d.llist:SetPoint("TOPLEFT", d.lwell, "TOPLEFT", 4, -4)

    d.history = sub(p, "GuildHub_DKPHistory")
    local h = d.history
    d.hexport = button(h, "Export history", 110, 18, function() G:ShowExport("DKP history", G:DKPExport(true)) end)
    d.hexport:SetPoint("TOPLEFT", h, "TOPLEFT", 0, -2)
    d.hcount = label(h, 10, MUTED)
    d.hcount:SetPoint("TOPRIGHT", h, "TOPRIGHT", -2, -5)
    d.hcount:SetJustifyH("RIGHT")
    d.hwell = inset(h, 0, -24, PAGE_W, 400)
    d.hlist = entryList(d.hwell, "GuildHub_HistoryList")
    d.hlist:SetPoint("TOPLEFT", d.hwell, "TOPLEFT", 4, -4)

    -- council
    d.council = sub(p, "GuildHub_Council")
    local c = d.council
    d.citem = box(c, "GuildHub_CouncilItem", 260, 60, "Item to vote on")
    d.citem:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -2)
    d.copen = button(c, "Open vote", 90, 18, function()
        if G:OpenVote(d.citem:GetText()) then d.citem:SetText("") end
    end)
    d.copen:SetPoint("LEFT", d.citem, "RIGHT", 4, 0)
    d.cclosed = button(c, "Show closed", 96, 18, function() d.showClosed = not d.showClosed; G:Render() end)
    d.cclosed:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, -2)
    d.cnote = label(c, 10, MUTED, 2, -6, PAGE_W - 110)
    d.cwell = inset(c, 0, -24, PAGE_W, 400)
    d.clist = UI.ScrollList(d.cwell, { name = "GuildHub_CouncilList", width = PAGE_W - 8, height = 392, rowHeight = 48,
        build = function(row, i)
            hl(row)
            row.itemName = UI.Label(row, 12, UI.ACCENT, "OUTLINE")
            row.itemName:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
            row.state = label(row, 10, MUTED)
            row.state:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -5)
            row.state:SetJustifyH("RIGHT")
            row.tally = label(row, 10, TEXT)
            row.tally:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -22)
            row.tally:SetWidth(PAGE_W - 180)
            row.close = button(row, "Close & award", 100, 18, function()
                local x = row.session
                if not x then return end
                local t = G:Tally(x.id)
                UI.Prompt({ title = "Award " .. plain(x.item), text = "Winner " .. (t[1] and t[1].cand or "?") .. ". DKP cost:", default = "0", maxLetters = 6,
                    accept = "Award", onAccept = function(v) G:CloseVote(x.id, nil, tonumber(v) or 0) end })
            end)
            row.close:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 4)
            row.vote = button(row, "Vote", 60, 18, function()
                local x = row.session
                if not x then return end
                local items = { { text = "Vote for...", title = true } }
                local mine = G.GDB().vo[x.id .. "/" .. me()]
                for _, n in ipairs(G.SplitList(x.cands, ":")) do
                    local name = n
                    tinsert(items, { text = name .. "  (" .. G:Points(name) .. " DKP)", checked = mine and mine.cand == name,
                        func = function() G:Vote(x.id, name) end })
                end
                tinsert(items, { text = "Someone else...", func = function()
                    UI.Prompt({ title = "Vote", text = "Who should get " .. plain(x.item) .. "?", maxLetters = 12, accept = "Vote",
                        onAccept = function(v) G:Vote(x.id, v) end })
                end })
                UI.Menu(row.vote, items)
            end)
            row.vote:SetPoint("RIGHT", row.close, "LEFT", -3, 0)
            setglobal("GuildHub_CouncilRow" .. i, row)
        end,
        update = function(row, x)
            row.session = x
            row.itemName:SetText(plain(x.item or "?"))
            local open = (x.open or 0) == 1
            row.state:SetText(open and ("Open " .. DOT .. " " .. (G.Ago(x.t) or "") .. " " .. DOT .. " " .. plain(x.by or ""))
                or ("|cff60e070Won by " .. plain(x.winner or "?") .. "|r for " .. (x.cost or 0) .. " DKP"))
            local bits = {}
            for _, t in ipairs(G:Tally(x.id)) do
                tinsert(bits, plain(t.cand) .. " |cffffd100" .. t.n .. "|r |cff9da3b4(" .. table.concat(t.voters, ", ") .. ")|r")
            end
            row.tally:SetText(bits[1] and table.concat(bits, "  " .. DOT .. "  ") or "|cff9da3b4No votes yet.|r")
            local officer = G:IsOfficer()
            show(row.vote, open and officer)
            show(row.close, open and officer)
        end,
    })
    d.clist:SetPoint("TOPLEFT", d.cwell, "TOPLEFT", 4, -4)
    d.cempty = label(d.cwell, 11, MUTED)
    d.cempty:SetPoint("CENTER", d.cwell, "CENTER", 0, 0)
    d.cempty:SetWidth(PAGE_W - 80)
    d.cempty:SetJustifyH("CENTER")
    return d
end

local function renderDKP(p, which)
    local d = ui.dkp
    local officer = G:IsOfficer()
    for _, k in ipairs({ "standings", "loot", "history", "council" }) do show(d[k], k == which) end
    p.hint:SetText(G.Cfg().tick .. " DKP per boss kill" .. (G.Cfg().council == 1 and (" " .. DOT .. " loot council on") or ""))
    if which == "standings" then
        local list = G:Standings()
        d.list:SetItems(list)
        d.count:SetText(getn(list) .. " players")
        show(d.tick, officer)
        show(d.award, officer)
        show(d.empty, not list[1])
    elseif which == "loot" then
        local out = {}
        for _, x in ipairs(G:DKPEntries()) do if x.kind == "loot" then tinsert(out, x) end end
        d.llist:SetItems(out)
        for _, x in ipairs({ d.lwin, d.litem, d.lcost, d.lbtn }) do show(x, officer) end
        show(d.lhint, not officer)
        d.lhint:SetText("Loot the officers awarded, newest first.")
    elseif which == "history" then
        local all = G:DKPEntries()
        d.hlist:SetItems(all)
        d.hcount:SetText(getn(all) .. " entries" .. (officer and (" " .. DOT .. " click one to void it") or ""))
    else
        local on = G.Cfg().council == 1
        local votes = G:Votes(d.showClosed)
        d.clist:SetItems(on and votes or {})
        show(d.citem, on and officer)
        show(d.copen, on and officer)
        show(d.cnote, not (on and officer))
        d.cnote:SetText(on and "Officers open a vote per item and vote for who gets it." or "")
        d.cclosed:SetText(d.showClosed and "Hide closed" or "Show closed")
        show(d.cempty, not (on and votes[1]))
        d.cempty:SetText(on and "No open votes." or "Loot council mode is off. An officer turns it on in Guild > Setup.")
    end
end

-- -- Guild: MOTD, officer chat, achievements, setup --------------------------------------------

local function buildGuild(p)
    local g = {}
    -- MOTD
    g.motd = sub(p, "GuildHub_MOTD")
    local m = g.motd
    g.cur = label(m, 10, { 0.55, 0.95, 0.55 }, 2, -2, PAGE_W - 4)
    local cap = UI.Label(m, 10, MUTED, "OUTLINE")
    cap:SetPoint("TOPLEFT", m, "TOPLEFT", 2, -30)
    cap:SetText("TEMPLATES")
    g.twell = inset(m, 0, -42, PAGE_W, 168)
    g.tlist = UI.ScrollList(g.twell, { name = "GuildHub_TemplateList", width = PAGE_W - 8, height = 160, rowHeight = 20,
        build = function(row, i)
            hl(row)
            row.text = label(row, 10, TEXT)
            row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
            row.text:SetWidth(PAGE_W - 30)
            row:SetScript("OnClick", function()
                if row.item then g.picked = row.item; g.box:SetText(row.item.text); G:Render() end
            end)
            setglobal("GuildHub_TemplateRow" .. i, row)
        end,
        update = function(row, t)
            row.text:SetText((t.builtin and "" or "|cffffd100*|r ") .. plain(t.text))
        end,
    })
    g.tlist:SetPoint("TOPLEFT", g.twell, "TOPLEFT", 4, -4)
    g.box = box(m, "GuildHub_MOTDText", PAGE_W, 128, "Message of the day: {next} {banker} {guild} {date} fill themselves in",
        function() if G.built then G:Render() end end)
    g.box:SetPoint("TOPLEFT", m, "TOPLEFT", 0, -218)
    g.len = label(m, 10, MUTED)
    g.len:SetPoint("TOPRIGHT", m, "TOPRIGHT", -2, -242)
    g.len:SetJustifyH("RIGHT")
    local pc = UI.Label(m, 10, MUTED, "OUTLINE")
    pc:SetPoint("TOPLEFT", m, "TOPLEFT", 2, -244)
    pc:SetText("PREVIEW")
    g.preview = label(m, 11, { 0.55, 0.95, 0.55 }, 2, -260, PAGE_W - 4)
    g.set = button(m, "Set MOTD", 100, 22, function()
        if G:SetMOTD(g.box:GetText()) then W.Print("Guild Hub: message of the day set.") end
    end)
    g.set:SetPoint("TOPLEFT", m, "TOPLEFT", 0, -300)
    g.save = button(m, "Save as template", 120, 22, function() if G:SaveTemplate(g.box:GetText()) then G:Render() end end)
    g.save:SetPoint("LEFT", g.set, "RIGHT", 6, 0)
    g.delete = button(m, "Delete template", 120, 22, function()
        if g.picked and not g.picked.builtin and G:DeleteTemplate(g.picked.text) then g.picked = nil; G:Render() end
    end)
    g.delete:SetPoint("LEFT", g.save, "RIGHT", 6, 0)
    g.mhint = label(m, 10, MUTED, 2, -332, PAGE_W - 4)

    -- officer chat
    g.officer = sub(p, "GuildHub_OfficerChat")
    local o = g.officer
    g.owell = inset(o, 0, -2, PAGE_W, 380)
    g.olist = UI.ScrollList(g.owell, { name = "GuildHub_OfficerList", width = PAGE_W - 8, height = 372, rowHeight = 16,
        build = function(row, i)
            row.text = label(row, 10, { 0.45, 0.95, 0.45 })
            row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
            row.text:SetWidth(PAGE_W - 24)
            setglobal("GuildHub_OfficerRow" .. i, row)
        end,
        update = function(row, l)
            row.text:SetText("|cff7a7d86" .. date("%H:%M", l.t) .. "|r [" .. plain(l.from) .. "]: " .. plain(l.text))
        end,
    })
    g.olist:SetPoint("TOPLEFT", g.owell, "TOPLEFT", 4, -4)
    g.oempty = label(g.owell, 11, MUTED)
    g.oempty:SetPoint("CENTER", g.owell, "CENTER", 0, 0)
    g.osay = box(o, "GuildHub_OfficerText", PAGE_W - 70, 255, "Say to officers")
    g.osay:SetPoint("TOPLEFT", o, "TOPLEFT", 0, -390)
    local function send() if G:SendOfficer(g.osay:GetText()) then g.osay:SetText("") end end
    g.osay:SetScript("OnEnterPressed", send)
    g.osend = button(o, "Send", 64, 18, send)
    g.osend:SetPoint("LEFT", g.osay, "RIGHT", 4, 0)

    -- achievements
    g.ach = sub(p, "GuildHub_Achievements")
    local a = g.ach
    g.atotal = UI.Label(a, 14, UI.ACCENT, "OUTLINE")
    g.atotal:SetPoint("TOPLEFT", a, "TOPLEFT", 2, -4)
    g.asub = label(a, 10, MUTED, 2, -24, PAGE_W - 4)
    local half = floor(PAGE_W / 2) - 4
    g.awell1 = inset(a, 0, -44, half, 380)
    g.awell2 = inset(a, half + 8, -44, half, 380)
    local h1 = UI.Label(g.awell1, 10, MUTED, "OUTLINE") h1:SetPoint("TOPLEFT", g.awell1, "TOPLEFT", 8, -8) h1:SetText("TOP MEMBERS")
    local h2 = UI.Label(g.awell2, 10, MUTED, "OUTLINE") h2:SetPoint("TOPLEFT", g.awell2, "TOPLEFT", 8, -8) h2:SetText("RECENTLY EARNED")
    g.top, g.recent = {}, {}
    for i = 1, 14 do
        local l1 = label(g.awell1, 10, TEXT, 8, -10 - i * 18, half - 16)
        local l2 = label(g.awell2, 10, TEXT, 8, -10 - i * 18, half - 16)
        g.top[i], g.recent[i] = l1, l2
    end

    -- setup
    g.setup = sub(p, "GuildHub_Setup")
    local s = g.setup
    local function row(y, text)
        local l = label(s, 11, { 1, 1, 1 }, 2, y)
        l:SetText(text)
        return l
    end
    row(-6, "Banker character")
    g.banker = box(s, "GuildHub_SetupBanker", 120, 12, "Name")
    g.banker:SetPoint("TOPLEFT", s, "TOPLEFT", 170, -2)
    g.bankerSave = button(s, "Save", 60, 18, function() G:SetCfg({ banker = W.Trim(g.banker:GetText() or "") }) end)
    g.bankerSave:SetPoint("LEFT", g.banker, "RIGHT", 4, 0)
    label(s, 10, MUTED, 2, -24, PAGE_W - 4):SetText("Trades with this character are written to the bank log by themselves.")
    row(-50, "Officers are ranks up to")
    g.orank = button(s, "", 160, 18, function()
        local n = GuildControlGetNumRanks and GuildControlGetNumRanks() or 5
        local c = G.Cfg()
        local v = c.orank + 1
        if v > n - 2 then v = 0 end
        G:SetCfg({ orank = v })
    end)
    g.orank:SetPoint("TOPLEFT", s, "TOPLEFT", 170, -46)
    label(s, 10, MUTED, 2, -68, PAGE_W - 4):SetText("They add events, DKP and bank entries and vote in the loot council. Only the guild master changes this.")
    row(-94, "DKP per boss kill")
    g.tick = box(s, "GuildHub_SetupTick", 50, 4, "10")
    g.tick:SetPoint("TOPLEFT", s, "TOPLEFT", 170, -90)
    g.tick:SetNumeric(true)
    g.tickSave = button(s, "Save", 60, 18, function() G:SetCfg({ tick = tonumber(g.tick:GetText()) or 10 }) end)
    g.tickSave:SetPoint("LEFT", g.tick, "RIGHT", 4, 0)
    row(-122, "Loot council")
    g.council = button(s, "Off", 80, 18, function() G:SetCfg({ council = G.Cfg().council == 1 and 0 or 1 }) end)
    g.council:SetPoint("TOPLEFT", s, "TOPLEFT", 170, -118)
    label(s, 10, MUTED, 2, -142, PAGE_W - 4):SetText("Officers vote on who gets each item; closing a vote awards the item with its DKP cost.")
    g.sinfo = label(s, 10, MUTED, 2, -176, PAGE_W - 4)
    g.sinfo:SetHeight(60)
    return g
end

local function renderGuild(p, which)
    local g = ui.guild
    for _, k in ipairs({ "motd", "officer", "ach", "setup" }) do show(g[k], (k == "ach" and "achievements" or k) == which) end
    if which == "motd" then
        p.hint:SetText(G:CanMOTD() and "Pick a template or write your own" or "Only ranks that may edit the MOTD can set it")
        local cur = GetGuildRosterMOTD and GetGuildRosterMOTD() or ""
        g.cur:SetText("Now: " .. (cur ~= "" and plain(cur) or "|cff9da3b4(no message of the day)|r"))
        g.tlist:SetItems(G:Templates())
        local text = g.box:GetText() or ""
        local filled = G:FillTemplate(text)
        g.preview:SetText(plain(filled))
        g.len:SetText(strlen(filled) .. " / 128")
        if G:CanMOTD() and text ~= "" then g.set:Enable() else g.set:Disable() end
        show(g.delete, g.picked and not g.picked.builtin)
        g.mhint:SetText("Your templates are marked *. {next} is the next guild event, {banker} the banker, {guild} the guild, {date} today.")
    elseif which == "officer" then
        local ok = G:CanViewOfficerNote()
        p.hint:SetText(ok and "Officer chat, also in your chat window" or "")
        local lines = ok and G.officerLines or {}
        g.olist:SetItems(lines)
        g.olist:ScrollToEnd()
        show(g.osay, ok)
        show(g.osend, ok)
        show(g.oempty, not lines[1])
        g.oempty:SetText(ok and "No officer chat yet this session." or "Officer chat is for ranks that read officer notes.")
    elseif which == "achievements" then
        p.hint:SetText("From the Achievements addon of each member")
        local total, members, recent = G:AchievementSummary()
        g.atotal:SetText(total .. " achievement points")
        g.asub:SetText(Achievements and (getn(members) .. " members shared their points. Members share theirs when they log in.")
            or "Turn on Achievements in /addons to share your points with the guild.")
        for i = 1, 14 do
            local x = members[i]
            g.top[i]:SetText(x and (i .. ". " .. G.ColorName(x.name, memberToken(x.name)) .. "  |cffffd100" .. x.pts .. "|r") or "")
            local r = recent[i]
            g.recent[i]:SetText(r and (G.ColorName(r.name, memberToken(r.name)) .. "  " .. plain(r.a.n or "?") .. "  |cff9da3b4"
                .. (r.a.p or 0) .. " pts " .. DOT .. " " .. (G.Ago(r.t) or "") .. "|r") or "")
        end
    else
        local c = G.Cfg()
        local officer = G:IsOfficer()
        p.hint:SetText(officer and "Shared with the whole guild" or "Officers change these")
        -- refill the boxes only when the shared value changed (never under the officer's typing)
        if g.lastBanker ~= c.banker then g.lastBanker = c.banker; g.banker:SetText(c.banker or "") end
        if g.lastTick ~= c.tick then g.lastTick = c.tick; g.tick:SetText(c.tick) end
        g.orank:SetText(rankName(c.orank) .. " (" .. c.orank .. ")")
        g.council:SetText(c.council == 1 and "On" or "Off")
        for _, x in ipairs({ g.bankerSave, g.tickSave, g.council }) do if officer then x:Enable() else x:Disable() end end
        if officer and G:MyRank() == 0 then g.orank:Enable() else g.orank:Disable() end
        g.sinfo:SetText("Guild Hub " .. G.version .. ". Last changed by " .. (blank(c.by) and "nobody yet" or plain(c.by))
            .. ". Guild data syncs over the hidden CPGuild channel with the members who run Guild Hub; an officer online answers when you log in.")
    end
end

-- -- Show / render --------------------------------------------------------------------------------

local RENDER = { roster = renderRoster, recruit = renderRecruit, events = renderEvents, bank = renderBank, dkp = renderDKP, guild = renderGuild }

function G:Show(key, subKey)
    if not W:IsActive(ID) then W.Print("Guild Hub is switched off. Turn it on in /addons.") return end
    key = RENDER[key or ""] and key or self.tab
    self.tab = key
    if subKey and SUBS[key] then
        for _, s in ipairs(SUBS[key]) do if s.key == subKey then self.sub[key] = subKey end end
    end
    G.Char().tab = key
    if not win:IsShown() then win:Show() end
    if win.tabs:Selected() ~= key then win.tabs:Select(key, true) end
    win.tabs:SetUnread(key, false)
    self:Render()
end

function G:Toggle()
    if win:IsShown() then win:Hide() else self:Show(G.Char().tab) end
end

function G:Render()
    if not win:IsShown() or not self.built then return end
    local inGuild = G.GuildName() ~= nil
    show(none, not inGuild)
    local subs = SUBS[self.tab]
    if subs and inGuild then
        ui.subtabs:SetTabs(subs)
        ui.subtabs:Select(self.sub[self.tab], true)
        ui.subtabs:Show()
    else
        ui.subtabs:Hide()
    end
    for k, p in pairs(ui.pages) do show(p, inGuild and k == self.tab) end
    if not inGuild then ui.status:SetText("") return end
    local on = 0
    for _, m in ipairs(self.roster) do if m.online then on = on + 1 end end
    ui.status:SetText("<" .. plain(G.GuildName()) .. ">  " .. on .. " / " .. getn(self.roster) .. " online"
        .. (G.ChannelId() and "" or "  |cffff6a60(connecting)|r"))
    RENDER[self.tab](ui.pages[self.tab], self.sub[self.tab])
end

for _, t in ipairs(TABS) do page(t) end
ui.roster = buildRoster(ui.pages.roster)
ui.recruit = buildRecruit(ui.pages.recruit)
ui.events = buildEvents(ui.pages.events)
ui.bank = buildBank(ui.pages.bank)
ui.dkp = buildDKP(ui.pages.dkp)
ui.guild = buildGuild(ui.pages.guild)
G.built = true

win:SetScript("OnShow", function()
    if PlaySound then PlaySound("igCharacterInfoOpen") end
    if GuildRoster then GuildRoster() end
    G:Render()
end)
win:SetScript("OnHide", function()
    if PlaySound then PlaySound("igCharacterInfoClose") end
    if G.embedding then G:EmbedListing(false) end
end)

-- -- Settings, slash, registration --------------------------------------------------------------

G.SCHEMA = {
    title = "Guild Hub",
    icon = PORTRAIT,
    desc = "Your guild in one window: roster tools, recruitment and applications, events with sign-ups, the bank log, DKP and loot council, the MOTD. /gh",
    defaults = { toasts = true, toastEvents = true, reminders = true, toastSound = true, autoBank = true, autoTicks = true, declineWhisper = true },
    options = {
        { key = "toasts", label = "Toasts", sub = "Banners for new applications, events and loot council votes." },
        { key = "toastEvents", label = "New event toasts", sub = "A banner when an officer adds a guild event." },
        { key = "reminders", label = "Event reminders", sub = "A banner 30 and 5 minutes before each guild event you didn't decline." },
        { key = "toastSound", label = "Reminder sound", sub = "Play the raid warning sound with event reminders." },
        { key = "autoBank", label = "Log trades with the banker", sub = "Write trades with the guild's banker character to the bank log." },
        { key = "autoTicks", label = "DKP on boss kills", sub = "Officers: tick the raid's DKP when a raid boss dies." },
        { key = "declineWhisper", label = "Decline whisper", sub = "Whisper a polite note to applicants you decline." },
    },
}
W:RegisterSchema(ID, G.SCHEMA)

W:RegisterAddon(ID, function(active)
    if not active then
        win:Hide()
        export:Hide()
    end
end)

SLASH_GUILDHUB1 = "/guildhub"
SLASH_GUILDHUB2 = "/gh"
local SLASH = {
    roster = { "roster" }, recruit = { "recruit", "listing" }, apps = { "recruit", "apps" }, applications = { "recruit", "apps" },
    events = { "events" }, calendar = { "events" }, bank = { "bank", "log" }, requests = { "bank", "requests" },
    dkp = { "dkp", "standings" }, loot = { "dkp", "loot" }, history = { "dkp", "history" }, council = { "dkp", "council" },
    guild = { "guild" }, motd = { "guild", "motd" }, officer = { "guild", "officer" }, achievements = { "guild", "achievements" },
    setup = { "guild", "setup" },
}
SlashCmdList["GUILDHUB"] = function(msg)
    msg = strlower(W.Trim(msg or ""))
    if not W:IsActive(ID) then W.Print("Guild Hub is switched off. Turn it on in /addons.") return end
    if msg == "help" then
        W.Print("/gh [roster|recruit|apps|events|bank|requests|dkp|loot|history|council|motd|officer|achievements|setup]  " .. DOT .. "  /gh tick (DKP to the raid)")
        return
    end
    if msg == "tick" then
        if not G:IsOfficer() then W.Print("Guild Hub: only officers tick DKP.") return end
        if G:TickRaid("Attendance") then W.Print("Guild Hub: " .. G.Cfg().tick .. " DKP to everyone in the raid.")
        else W.Print("Guild Hub: join a raid to tick its members.") end
        return
    end
    local to = SLASH[msg]
    if to then return G:Show(to[1], to[2]) end
    G:Toggle()
end
