--[[
    BossFights.lua  (Open Vanilla / the Modes realm)
    The Boss Fights window. On a realm whose world server runs Boss Fights (OpenVanilla.BossFights = 1,
    realm/mangos/0027-openvanilla-bossfights.patch) it shows:
      Queue          the raid and tier, your role, Queue / Leave queue and the queue's state
      Party search   groups looking for players (Join), and a Refresh
      Tiers          every raid's five tiers (cleared, open, locked), your tier bonus, the fastest clears
      Armory         Warfront's kits and gear picker
    plus the "raid ready" pop, the run's timer (bosses down with their times, deaths, wipes, the twists)
    and the clear (time, the tier it opened). /bf opens the window.

    It talks through Warfront's channel: ".wnl wf bf <command>", answers on the addon tag BF:
      hi,<on>,<in mode>,<lobby raid>,<role>,<bonus %>,<raid>:<best>:<open>:<size>;...
      go,<raid>  mode,0  role,<tank|healer|dps>  q,<raid>,<tier>,<queued>,<waited s>  unq  idle
      lfg;<id>,<raid>,<tier>,<leader>,<size>,<T>:<H>:<D>,<note>;...  lfg,posted|dropped|joined,<id>  lfg,member,<name>
      pop,<run>,<raid>,<tier>,<affixes>  requeue  in,<run>,<raid>,<tier>,<size>  pull
      boss,<i>,<name>,<m:ss>  wipe,<n>  end,<cleared>,<m:ss>,<deaths>,<wipes>,<unlocked>  left
      run,<run>,<raid>,<tier>,<m:ss>,<done>/<total>  tiers;<raid>,<best>,<open>;...
      board,<raid>,<tier>;<m:ss>,<leader>,<size>,<ended>;...  err,<why>
      ready,level=,spec=,spent=,free=,sets=,setsof=,worn=,slots=,buttons=,consumables=,wanted=,missing=,ok=
        (realm patch 0052: the realm made this raider ready in the hangout; "ready" asks again)
      fill,<on>,<after s>   (realm patch 0054: bots fill a raid nobody else joins, after that many seconds)
      q,...,<still needed>,<bots state>,<s>,<ready>,<wanted>   (0054: wait|joining|ready|full|off|ai|memory|max|error)
      rbots,<n>             (0054: the run has n bots in it)
    Realm patch 0062 (the run's extras; realm/bossfights/README-run.md):
      kinds,<practice>,<hardcore>,<story>,<roulette>,<reset s>,<story people>   week,<twist>,<title>,<text>
      q,...,kind=<kind>[,roulette=1]   twist,<name>,<title>,<kind>,<roulette>   ghost,<best ms>,<record ms>,<holder>
      bhp,<boss %>,<phase>   reset,<s> | reset,go   spectate   rc,<people> | rc,no,<name> | rc,timeout,<names>
      pullin,10   pullnow   meters;<name>:<class>:<role>:<damage>:<healing>:<deaths>:<bot>;...
      recap,<who>|<what>|<amount>|<killing>;...   reward,<scales>,<egg>,<hoard item>,<feats+>   hatched,<item>
      feat,<key>,<title>   horn,<text> | horn,sent,<n>   shop;<scales>;<item>:<price>:<name>:<have>;...
      shop,bought,<item>,<scales left>   feats;<key>:<count>;...   hof;<raid>:<tier>:<m:ss>:<leader>[:bots];...
    Commands it sends besides: q <raid|roulette> <tier> [practice2|practice3|hardcore|story], pull, rc yes|no,
      reset, horn, shop, shop buy <item>, feats, hof.
    Every answer also comes as a chat line from the realm, so this window never repeats errors.
    Does nothing on other realms. Lua 5.0 rules: no #, no %, string.* functions, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W.UI
local F = Warfront

BossFights = BossFights or {}
local B = BossFights

local getn = table.getn
local ICON = "Interface\\Icons\\INV_Misc_Head_Dragon_01"

B.RAIDS = {
    onyxia = "Onyxia's Lair", mc = "Molten Core", bwl = "Blackwing Lair", zg = "Zul'Gurub",
    aq20 = "Ruins of Ahn'Qiraj", aq40 = "Temple of Ahn'Qiraj", naxx = "Naxxramas", any = "Any raid",
}
B.SHORT = { onyxia = "Onyxia", mc = "Molten Core", bwl = "BWL", zg = "Zul'Gurub", aq20 = "AQ20", aq40 = "AQ40", naxx = "Naxx", any = "Any raid" }
B.MAX_TIER = 5
B.AFFIX = { fortified = "Fortified", tyrannical = "Tyrannical", enrage = "Enrage" }
B.AFFIX_TIP = {
    fortified = "Trash: +25% health and damage.",
    tyrannical = "Bosses: +25% health and damage.",
    enrage = "Bosses hit 10% harder every 30 s after 3 minutes in one fight.",
}
B.ROLE_LABEL = { tank = "Tank", healer = "Healer", dps = "Damage" }

B.on = false          -- the realm runs Boss Fights
B.mode = false        -- this character is in Boss Fights (in Gurubashi or a run)
B.raids = {}          -- { { key, best, open, size } } in the realm's order
B.role = "dps"
B.bonus = 0
B.pick = { raid = nil, tier = 1, kind = "normal" }
B.queue = nil         -- { raid, tier, queued, since, bots = { state, at, ready, want } }
B.fill = nil          -- { on, after }: bots fill a raid nobody else joins (realm patch 0054)
B.posts = {}
B.board = nil         -- { raid, tier, rows }
B.run = nil           -- { id, raid, tier, size, affixes, pullAt, bosses = { {name, at} }, deaths, wipes, done, total }
B.result = nil        -- the last end line, for the clear screen
B.prep = nil          -- the realm's ready check: { level, spec, spent, sets, whole, worn, slots, buttons, have, want, ok }
-- realm patch 0062: the run's extras
B.kinds = nil         -- { practice, hardcore, story, roulette, reset, storyPeople }: what the realm offers
B.week = nil          -- { name, title, text }: this week's twist
B.scales = nil        -- Dragon Scales (from the shop line)
B.shop = {}           -- { { item, price, name, have } }
B.feats = {}          -- { { key, count } }
B.hof = {}            -- { { raid, tier, time, leader, bots } }
B.rc = nil            -- the ready check out: { people, at }
B.countdownAt = nil   -- GetTime() of the pull
B.endInfo = nil       -- the end screen's extras: { meters, recap, reward, feats }

B.KIND_LABEL = { normal = "Normal", practice2 = "Practice P2", practice3 = "Practice P3", hardcore = "Hardcore", story = "Story", roulette = "Roulette" }
B.KIND_TIP = {
    normal = "The raid as it comes: records, unlocks and rewards.",
    practice2 = "Onyxia starts at 64%: straight into her flying phase. No records, no unlocks.",
    practice3 = "Onyxia starts at 39%: straight into her last phase. No records, no unlocks.",
    hardcore = "One death and you watch the rest of the run. Its own board; a clear unlocks as usual.",
    story = "1 to 5 people, bots for the rest, a softer raid. No records.",
    roulette = "A random raid with a random twist. A Daredevil feat on a clear.",
}
B.FEAT_TITLE = { nodeaths = "Untouchable", under3 = "Swift as the Wind", nobreath = "Breath Dodger", botsonly = "Commander",
                 firsttry = "First Try", roulette = "Daredevil", hardcore = "Ironclad" }
B.CLASS_COLOR = { [1] = "c79c6e", [2] = "f58cba", [3] = "abd473", [4] = "fff569", [5] = "ffffff", [7] = "0070de", [8] = "69ccf0",
                  [9] = "9482c9", [11] = "ff7d0a" }

local function say(msg) W.Print("|cffff8000Boss Fights:|r " .. msg) end

-- realm patch 0052: a raider plays with all four extra action bars on (the realm fills them)
function B.ShowBars()
    if SetActionBarToggles then SetActionBarToggles(1, 1, 1, 1) end
    SHOW_MULTI_ACTIONBAR_1, SHOW_MULTI_ACTIONBAR_2, SHOW_MULTI_ACTIONBAR_3, SHOW_MULTI_ACTIONBAR_4 = 1, 1, 1, 1
    if MultiActionBar_Update then MultiActionBar_Update() end
end

-- the ready check in words (the Armory page)
function B.PrepText()
    local r = B.prep
    if not r then return "Getting you ready in Gurubashi: level 60, your role's talents, gear sets, consumables and bars." end
    local worn = r.worn
    if worn == "-" then worn = "nothing yet" elseif worn == "own" then worn = "your own gear" elseif worn == "mixed" then worn = "pieces of several sets" end
    return (r.ok and "|cff40ff40Ready.|r " or "|cffffd100Getting ready.|r ") .. "Level " .. r.level .. ", " .. r.spec .. " (" .. r.spent .. " talent points). " ..
           r.whole .. " of " .. r.sets .. " gear sets in your bags, wearing " .. worn .. ". " ..
           r.have .. " of " .. r.want .. " consumables, " .. r.buttons .. " buttons on your bars, " .. r.slots .. " free bag slots."
end
B.Say = say

function B.Send(args)
    if not B.on then return nil end
    return W:SendCommand("wf", "bf " .. args)
end
local send = B.Send

local function raidName(k) return B.RAIDS[k or ""] or tostring(k) end
local function raidShort(k) return B.SHORT[k or ""] or raidName(k) end

local function affixText(s)
    if not s or s == "" or s == "none" then return "" end
    local out = {}
    for _, a in ipairs(W.Split(s, "+")) do table.insert(out, B.AFFIX[a] or a) end
    return table.concat(out, " + ")
end
B.AffixText = affixText

-- m:ss from seconds
local function clock(sec)
    sec = math.floor(sec or 0)
    if sec < 0 then sec = 0 end
    local h, m, s = math.floor(sec / 3600), math.floor(sec / 60) - math.floor(sec / 3600) * 60, sec - math.floor(sec / 60) * 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end
B.Clock = clock

-- "12:34" / "1:02:03" to seconds
local function seconds(t)
    local p = W.Split(t or "", ":")
    local n = getn(p)
    if n == 3 then return (tonumber(p[1]) or 0) * 3600 + (tonumber(p[2]) or 0) * 60 + (tonumber(p[3]) or 0) end
    if n == 2 then return (tonumber(p[1]) or 0) * 60 + (tonumber(p[2]) or 0) end
    return tonumber(t) or 0
end

-- 12345 -> "12.3k", 1234567 -> "1.23M"
function B.Short(n)
    n = tonumber(n) or 0
    if n >= 1000000 then return string.format("%.2fM", n / 1000000) end
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(math.floor(n))
end

local function raidInfo(k)
    for _, r in ipairs(B.raids) do if r.key == k then return r end end
end

local function partySize()
    local n = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    if n > 0 then return n end
    n = (GetNumPartyMembers and GetNumPartyMembers()) or 0
    return n > 0 and (n + 1) or 1
end

local function isLeader()
    if partySize() <= 1 then return true end
    if IsPartyLeader then return IsPartyLeader() and true or false end
    return true
end

-- -- small pieces ------------------------------------------------------------------------------

-- A choice button: dark, lit gold when chosen, greyed when locked.
local function choice(parent, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(w)
    b:SetHeight(h)
    b:SetBackdrop(UI.THIN)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("CENTER", b, "CENTER", 0, 4)
    b.sub = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    b.sub:SetPoint("TOP", b.label, "BOTTOM", 0, -1)
    b:SetScript("OnClick", function() if not b.locked and onClick then onClick(b) end end)
    b:SetScript("OnEnter", function()
        if b.tip and GameTooltip then
            GameTooltip:SetOwner(b, "ANCHOR_TOP")
            GameTooltip:SetText(b.tip, 1, 1, 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    function b:Set(text, sub, on, locked)
        self.label:SetText(text or "")
        self.sub:SetText(sub or "")
        self.label:ClearAllPoints()
        self.label:SetPoint("CENTER", self, "CENTER", 0, (sub and sub ~= "") and 4 or 0)
        self.on, self.locked = on and true or false, locked and true or false
        if self.locked then
            self:SetBackdropColor(0.05, 0.05, 0.06, 0.8)
            self:SetBackdropBorderColor(0.25, 0.24, 0.22, 1)
            self.label:SetTextColor(0.45, 0.45, 0.45)
        elseif self.on then
            self:SetBackdropColor(0.32, 0.22, 0.06, 0.95)
            self:SetBackdropBorderColor(1, 0.82, 0.3, 1)
            self.label:SetTextColor(1, 0.85, 0.3)
        else
            self:SetBackdropColor(0.08, 0.07, 0.06, 0.9)
            self:SetBackdropBorderColor(0.45, 0.38, 0.24, 1)
            self.label:SetTextColor(0.92, 0.9, 0.85)
        end
    end
    b:Set("", nil, false, false)
    return b
end

local function heading(parent, text, x, y)
    local t = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    t:SetText(text)
    return t
end

local function textLine(parent, font, x, y, w)
    local t = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    if w then t:SetWidth(w) end
    t:SetJustifyH("LEFT")
    return t
end

-- -- the window -----------------------------------------------------------------------------------

local win
local W_WIDTH, W_HEIGHT = 380, 372

local function page(name)
    local p = CreateFrame("Frame", nil, win)
    p:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -52)
    p:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 28)
    p:Hide()
    win.pages[name] = p
    return p
end

local function buildQueue(p)
    heading(p, "Raid", 0, 0)
    p.raidButtons = {}
    p.tierButtons = {}
    for i = 1, 3 do
        local b = choice(p, 116, 26, function(btn) B.pick.raid = btn.key; B:ClampTier(); B:Refresh() end)
        b:SetPoint("TOPLEFT", p, "TOPLEFT", (i - 1) * 121, -14)
        p.raidButtons[i] = b
    end
    heading(p, "Tier |cff9a9a9a- clear a tier to open the next|r", 0, -48)
    for t = 1, B.MAX_TIER do
        local b = choice(p, 68, 30, function(btn) B.pick.tier = btn.tier; B:Refresh() end)
        b.tier = t
        b:SetPoint("TOPLEFT", p, "TOPLEFT", (t - 1) * 72, -62)
        p.tierButtons[t] = b
    end
    heading(p, "Your role", 0, -102)
    p.roleButtons = {}
    local roles = { "tank", "healer", "dps" }
    for i, r in ipairs(roles) do
        local key = r
        local b = choice(p, 116, 26, function() B.role = key; send("role " .. key); B:Refresh() end)
        b:SetPoint("TOPLEFT", p, "TOPLEFT", (i - 1) * 121, -116)
        b.key = key
        p.roleButtons[i] = b
    end
    -- realm patch 0062: the kind of run
    p.kindButtons = {}
    local kinds = { "normal", "practice2", "practice3", "hardcore", "story", "roulette" }
    for i, k in ipairs(kinds) do
        local key = k
        local b = choice(p, 57, 20, function() B.pick.kind = key; B:Refresh() end)
        b:SetPoint("TOPLEFT", p, "TOPLEFT", (i - 1) * 60, -146)
        b.key = key
        p.kindButtons[i] = b
    end
    p.party = textLine(p, "GameFontHighlightSmall", 0, -170, 358)
    local q = UI.Button(p, "Queue up", 116, 24, function() B:Queue() end)
    q:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -184)
    p.queueBtn = q
    local leave = UI.Button(p, "Leave queue", 116, 24, function() send("unq") end)
    leave:SetPoint("LEFT", q, "RIGHT", 5, 0)
    p.leaveBtn = leave
    local horn = UI.Button(p, "Rally Horn", 116, 24, function() send("horn") end)
    horn:SetPoint("LEFT", leave, "RIGHT", 5, 0)
    horn.tip = "Calls the Boss Fights players in Gurubashi to your waiting line (once a minute)."
    p.hornBtn = horn
    -- the queue's state
    local box = CreateFrame("Frame", nil, p)
    box:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -214)
    box:SetWidth(358)
    box:SetHeight(62)
    box:SetBackdrop(UI.THIN)
    box:SetBackdropColor(0.04, 0.035, 0.03, 0.9)
    box:SetBackdropBorderColor(0.55, 0.45, 0.2, 1)
    box.state = textLine(box, "GameFontHighlight", 10, -8, 250)
    box.time = box:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    box.time:SetPoint("TOPRIGHT", box, "TOPRIGHT", -10, -6)
    box.detail = textLine(box, "GameFontHighlightSmall", 10, -30, 338)
    box.bar = UI.Bar and UI.Bar(box, { width = 338, height = 6 }) or nil
    if box.bar then box.bar:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", 10, 8) end
    p.box = box
end

local function buildParty(p)
    heading(p, "Groups looking for players", 0, 0)
    local refresh = UI.Button(p, "Refresh", 80, 20, function() send("lfg") end)
    refresh:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 2)
    p.rows = {}
    for i = 1, 6 do
        local r = CreateFrame("Frame", nil, p)
        r:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -18 - (i - 1) * 40)
        r:SetWidth(358)
        r:SetHeight(36)
        r:SetBackdrop(UI.THIN)
        r:SetBackdropColor(0.07, 0.06, 0.05, 0.9)
        r:SetBackdropBorderColor(0.35, 0.3, 0.2, 1)
        r.title = textLine(r, "GameFontNormalSmall", 8, -5, 260)
        r.detail = textLine(r, "GameFontHighlightSmall", 8, -19, 260)
        local j = UI.Button(r, "Join", 60, 20, function() if r.id then send("lfg join " .. r.id) end end)
        j:SetPoint("RIGHT", r, "RIGHT", -6, 0)
        r.join = j
        r:Hide()
        p.rows[i] = r
    end
    p.empty = textLine(p, "GameFontDisable", 0, -24, 358)
    p.empty:SetText("Nobody is looking for players right now. Queue on the Queue tab: the realm makes the group.")
    local post = UI.Button(p, "Post my group", 140, 22, function() B:Post() end)
    post:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 0, 0)
    p.postBtn = post
    local drop = UI.Button(p, "Remove my post", 140, 22, function() send("lfg drop") end)
    drop:SetPoint("LEFT", post, "RIGHT", 6, 0)
end

local function buildTiers(p)
    p.bonus = textLine(p, "GameFontNormal", 0, 0, 358)
    p.lines = {}
    for i = 1, 4 do
        local row = CreateFrame("Frame", nil, p)
        row:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -22 - (i - 1) * 54)
        row:SetWidth(358)
        row:SetHeight(50)
        row.name = textLine(row, "GameFontHighlight", 0, 0, 200)
        row.cells = {}
        for t = 1, B.MAX_TIER do
            local c = choice(row, 68, 30, function(btn)
                if row.key then
                    B.pick.raid, B.pick.tier = row.key, btn.tier
                    send("board " .. row.key .. " " .. btn.tier)
                end
            end)
            c.tier = t
            c:SetPoint("TOPLEFT", row, "TOPLEFT", (t - 1) * 72, -16)
            row.cells[t] = c
        end
        row:Hide()
        p.lines[i] = row
    end
    p.boardTitle = textLine(p, "GameFontNormalSmall", 0, -244, 358)
    p.board = textLine(p, "GameFontHighlightSmall", 0, -258, 358)
end

local function buildArmory(p)
    local t = textLine(p, "GameFontHighlight", 0, 0, 358)
    t:SetText("Your gear for Boss Fights comes from the armory: Warfront's kits (every slot filled and enchanted) and the gear picker.")
    p.tier = textLine(p, "GameFontNormal", 0, -48, 358)
    -- on the Modes realm (Duels and Boss Fights) the Armory window is the gear picker; Warfront's own window
    -- stays out of the way there
    local open = UI.Button(p, "Open the gear picker", 176, 26, function()
        local DA = Duels and Duels.on and Duels.Armory
        if DA and DA.Show then DA.Show()
        elseif F and F.Toggle then F:Toggle("kits") end
    end)
    open:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -78)
    local note = textLine(p, "GameFontDisableSmall", 0, -114, 358)
    note:SetText("Clearing tiers opens better gear: tier 2 gear after any clear, tier 3 gear after a tier 3 clear. Consumables are topped up every time you enter a raid.")
    -- realm patch 0052: what the realm set up (every gear set in the bags, the role's set worn)
    heading(p, "Ready check", 0, -150)
    p.prep = textLine(p, "GameFontHighlightSmall", 0, -166, 358)
    local again = UI.Button(p, "Check again", 120, 22, function() send("ready") end)
    again:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -222)
end

-- realm patch 0062: Dragon Scales, the Hoard Keeper's shop, your feats and this week's Hall of Fame
local function buildRewards(p)
    p.scales = textLine(p, "GameFontNormal", 0, 0, 358)
    heading(p, "The Hoard Keeper |cff9a9a9a- cosmetic, soulbound, never for money|r", 0, -20)
    p.rows = {}
    for i = 1, 6 do
        local r = CreateFrame("Frame", nil, p)
        r:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -34 - (i - 1) * 22)
        r:SetWidth(358)
        r:SetHeight(20)
        r.name = textLine(r, "GameFontHighlightSmall", 4, -4, 240)
        local b = UI.Button(r, "Buy", 56, 18, function() if r.item then send("shop buy " .. r.item) end end)
        b:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        r.buy = b
        r:Hide()
        p.rows[i] = r
    end
    p.more = UI.Button(p, "More", 56, 18, function() p.offset = (p.offset or 0) + 6; B:Refresh() end)
    p.more:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, -18)
    heading(p, "Your feats", 0, -170)
    p.feats = textLine(p, "GameFontHighlightSmall", 0, -184, 358)
    heading(p, "Hall of Fame |cff9a9a9a- this week's fastest|r", 0, -214)
    p.hof = textLine(p, "GameFontHighlightSmall", 0, -228, 358)
end

function B:Build()
    if win then return win end
    win = UI.Window("BossFightsFrame", { width = W_WIDTH, height = W_HEIGHT, title = "Boss Fights", icon = ICON, skin = true,
                                        point = { "CENTER", UIParent, "CENTER", 0, 40 } })
    win:Hide()
    B.win = win
    win.pages = {}
    local tabs = UI.Tabs(win, {
        skin = true,
        tabs = { { key = "queue", label = "Queue" }, { key = "party", label = "Party search" },
                 { key = "tiers", label = "Tiers" }, { key = "armory", label = "Armory" }, { key = "rewards", label = "Rewards" } },
        onSelect = function(key) B:ShowPage(key) end,
    })
    tabs:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -28)
    win.tabs = tabs
    buildQueue(page("queue"))
    buildParty(page("party"))
    buildTiers(page("tiers"))
    buildArmory(page("armory"))
    buildRewards(page("rewards"))
    win.foot = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    win.foot:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 12, 10)
    local go = UI.Button(win, "Go to Gurubashi", 120, 18, function() send("go") end)
    go:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 6)
    win.go = go
    B:ShowPage("queue")
    return win
end

function B:ShowPage(key)
    if not win then return end
    for k, p in pairs(win.pages) do if k == key then p:Show() else p:Hide() end end
    win.page = key
    if key == "party" then send("lfg") end
    if key == "tiers" then send("tiers") end
    if key == "rewards" then send("shop"); send("feats"); send("hof") end
    B:Refresh()
end

function B:Show()
    B:Build()
    win:Show()
    B:Refresh()
end

function B:Toggle()
    if not B.on then return say("Boss Fights works on a Boss Fights realm only.") end
    B:Build()
    if win:IsShown() then win:Hide() else B:Show() end
end

-- the picked tier never above what is open for the picked raid
function B:ClampTier()
    local r = raidInfo(B.pick.raid)
    local open = r and r.open or 1
    if B.pick.raid == "any" then open = B.MAX_TIER end
    if B.pick.tier > open then B.pick.tier = open end
    if B.pick.tier < 1 then B.pick.tier = 1 end
end

function B:Queue()
    if B.run then return say("You're in a raid. Leave it first (/bf abandon).") end
    if not isLeader() then return say("Your party's leader queues the whole party.") end
    local raid = B.pick.raid or "any"
    local kind = B.pick.kind or "normal"
    -- realm patch 0062: the kind of run (Raid Roulette draws the raid; practice is Onyxia's)
    if kind == "roulette" then return send("q roulette " .. (B.pick.tier or 1)) end
    if (kind == "practice2" or kind == "practice3") and raid ~= "onyxia" then raid = "onyxia" end
    send("q " .. raid .. " " .. (B.pick.tier or 1) .. ((kind ~= "normal") and (" " .. kind) or ""))
end

-- whether the realm offers a kind of run (an older realm: only the normal one)
function B.KindOffered(k)
    if k == "normal" then return true end
    local o = B.kinds
    if not o then return false end
    if k == "practice2" or k == "practice3" then return o.practice end
    return o[k] and true or false
end

function B:Post()
    local raid = B.pick.raid
    if not raid or raid == "any" then raid = B.raids[1] and B.raids[1].key or "onyxia" end
    local r = raidInfo(raid)
    local size = r and r.size or 10
    local have = partySize()
    local needT, needH = 2, 2
    if B.role == "tank" then needT = 1 elseif B.role == "healer" then needH = 1 end
    local needD = size - have - needT - needH + (B.role == "dps" and 0 or 1)
    if needD < 0 then needD = 0 end
    send("lfg post " .. raid .. " " .. (B.pick.tier or 1) .. " " .. needT .. " " .. needH .. " " .. needD)
end

local function refreshQueue(p)
    -- raids: the realm's (at most two), then "Any raid"
    local list = {}
    for _, r in ipairs(B.raids) do table.insert(list, r.key) end
    table.insert(list, "any")
    if not B.pick.raid then B.pick.raid = list[1] end
    for i, b in ipairs(p.raidButtons) do
        local k = list[i]
        if k then
            b.key = k
            b:Set(raidShort(k), nil, B.pick.raid == k, false)
            b:Show()
        else
            b:Hide()
        end
    end
    local r = raidInfo(B.pick.raid)
    local best, open = r and r.best or 0, r and r.open or 1
    if B.pick.raid == "any" then best, open = 0, B.MAX_TIER end
    for t, b in ipairs(p.tierButtons) do
        local sub
        if t <= best then sub = "cleared" elseif t <= open then sub = "open" else sub = "locked" end
        b.tip = (t <= open) and ("Tier " .. t .. (t > 1 and (": " .. (B.TIER_TIP[t] or "")) or ": the raid as you know it.")) or
                ("Locked: clear tier " .. (t - 1) .. " of " .. raidName(B.pick.raid) .. " to open it.")
        b:Set("T" .. t, sub, B.pick.tier == t, t > open)
    end
    for _, b in ipairs(p.roleButtons) do b:Set(B.ROLE_LABEL[b.key], nil, B.role == b.key, false) end
    if not B.KindOffered(B.pick.kind or "normal") then B.pick.kind = "normal" end
    for _, b in ipairs(p.kindButtons) do
        local offered = B.KindOffered(b.key)
        b.tip = offered and B.KIND_TIP[b.key] or "Not offered on this realm."
        b:Set(B.KIND_LABEL[b.key], nil, (B.pick.kind or "normal") == b.key, not offered)
    end
    local n = partySize()
    if n > 1 then
        p.party:SetText("Going as your party (" .. n .. ")" .. (isLeader() and ": you queue for everyone." or ": your leader queues."))
    else
        local size = (r and r.size) or 10
        if B.fill and B.fill.on then
            if B.fill.after > 0 then
                p.party:SetText("Going solo: if nobody else comes in " .. B.fill.after .. " s, bots fill the raid (" .. size .. " players).")
            else
                p.party:SetText("Going solo: bots fill the raid at once (" .. size .. " players).")
            end
        else
            p.party:SetText("Going solo: the raid starts when " .. size .. " players have queued.")
        end
    end
    local box = p.box
    if B.run then
        box.state:SetText("In " .. raidName(B.run.raid) .. ", tier " .. B.run.tier)
        box.time:SetText(B.run.pullAt and clock(GetTime() - B.run.pullAt) or "0:00")
        box.detail:SetText((B.run.done or 0) .. " of " .. (B.run.total or "?") .. " bosses down")
        if box.bar then box.bar:Hide() end
        p.queueBtn:Disable()
        p.leaveBtn:Disable()
        p.hornBtn:Disable()
    elseif B.queue then
        local size = (raidInfo(B.queue.raid) or {}).size or 10
        box.state:SetText("In queue · " .. raidName(B.queue.raid) .. ", Tier " .. B.queue.tier ..
                          ((B.queue.kind and B.queue.kind ~= "normal") and (" · " .. (B.KIND_LABEL[B.queue.kind] or B.queue.kind)) or "") ..
                          (B.queue.roulette and " · Roulette" or ""))
        box.time:SetText(clock(GetTime() - B.queue.since))
        local found = math.min(size, B.queue.queued or 1)
        box.detail:SetText("|cffffd100" .. found .. "/" .. size .. " found|r  · " .. B.BotsText(B.queue.bots))
        if box.bar then
            box.bar:Show()
            if box.bar.SetMinMaxValues then box.bar:SetMinMaxValues(0, size); box.bar:SetValue(found) end
        end
        p.queueBtn:Disable()
        p.leaveBtn:Enable()
        p.hornBtn:Enable()
    else
        box.state:SetText("Not queued")
        box.time:SetText("")
        local wk = B.week and B.week.name ~= "none" and ("|cffff8040This week: " .. B.week.title .. "|r - " .. B.week.text .. " ") or ""
        box.detail:SetText(wk .. "Pick a raid, a tier and your role, then Queue. Your group gets its own copy of the raid.")
        p.hornBtn:Disable()
        if box.bar then box.bar:Hide() end
        if isLeader() then p.queueBtn:Enable() else p.queueBtn:Disable() end
        p.leaveBtn:Disable()
    end
end

local function refreshParty(p)
    local shown = 0
    for i, r in ipairs(p.rows) do
        local o = B.posts[i]
        if o then
            r.id = o.id
            r.title:SetText(o.leader .. "'s group  |cffffd100" .. raidName(o.raid) .. ", Tier " .. o.tier .. "|r")
            local need = {}
            if o.t > 0 then table.insert(need, o.t .. " tank" .. (o.t > 1 and "s" or "")) end
            if o.h > 0 then table.insert(need, o.h .. " healer" .. (o.h > 1 and "s" or "")) end
            if o.d > 0 then table.insert(need, o.d .. " damage") end
            r.detail:SetText(o.size .. " in the group · needs " .. (need[1] and table.concat(need, ", ") or "anyone") ..
                             ((o.note and o.note ~= "") and (" · " .. o.note) or ""))
            local info = raidInfo(o.raid)
            local open = info and info.open or 1
            if o.tier > open then r.join:Disable() else r.join:Enable() end
            r:Show()
            shown = shown + 1
        else
            r.id = nil
            r:Hide()
        end
    end
    if shown == 0 then p.empty:Show() else p.empty:Hide() end
end

local function refreshTiers(p)
    p.bonus:SetText("Your tier bonus: |cff40ff40+" .. (B.bonus or 0) .. "%|r to every stat in Boss Fights (best clear in any raid, +2% a tier, at most +10%)")
    for i, row in ipairs(p.lines) do
        local r = B.raids[i]
        if r then
            row.key = r.key
            row.name:SetText(raidName(r.key) .. (r.best > 0 and ("  |cff9a9a9acleared tier " .. r.best .. "|r") or ""))
            for t, c in ipairs(row.cells) do
                local sub
                if t <= r.best then sub = "cleared" elseif t <= r.open then sub = "open" else sub = "locked" end
                c.tip = (t <= r.open) and "Show the fastest clears" or ("Clear tier " .. (t - 1) .. " to open it.")
                c:Set("T" .. t, sub, t <= r.best, t > r.open)
            end
            row:Show()
        else
            row.key = nil
            row:Hide()
        end
    end
    if B.board then
        p.boardTitle:SetText("Fastest clears · " .. raidName(B.board.raid) .. ", Tier " .. B.board.tier)
        local lines = {}
        for i, b in ipairs(B.board.rows) do
            table.insert(lines, i .. ".  " .. b.time .. "   " .. b.leader .. "'s group (" .. b.size .. ")")
        end
        p.board:SetText(lines[1] and table.concat(lines, "\n") or "No clears yet. Be the first.")
    else
        p.boardTitle:SetText("Click a tier to see its fastest clears.")
        p.board:SetText("")
    end
end

local function refreshRewards(p)
    p.scales:SetText("Dragon Scales: |cffffd100" .. (B.scales or 0) .. "|r  |cff9a9a9a(a clear gives some; a first clear of a tier adds a Dragon Egg - five hatch a whelp)|r")
    local off = p.offset or 0
    if off >= getn(B.shop) then off = 0; p.offset = 0 end
    for i, r in ipairs(p.rows) do
        local o = B.shop[off + i]
        if o then
            r.item = o.item
            r.name:SetText(o.name .. "  |cffffd100" .. o.price .. " scales|r" .. (o.have and "  |cff40ff40(have)|r" or ""))
            if (B.scales or 0) >= o.price then r.buy:Enable() else r.buy:Disable() end
            r:Show()
        else
            r.item = nil
            r:Hide()
        end
    end
    if getn(B.shop) > 6 then p.more:Show() else p.more:Hide() end
    local f = {}
    for _, x in ipairs(B.feats) do table.insert(f, (B.FEAT_TITLE[x.key] or x.key) .. " x" .. x.count) end
    p.feats:SetText(f[1] and table.concat(f, ", ") or "None yet: clear with nobody dead, under 3 minutes, without a Deep Breath hit, as one with bots, first try...")
    local h = {}
    for _, x in ipairs(B.hof) do
        table.insert(h, raidShort(x.raid) .. " T" .. x.tier .. ":  |cffffd100" .. x.time .. "|r  " .. x.leader .. "'s raid" .. (x.bots and " (bots)" or ""))
    end
    p.hof:SetText(h[1] and table.concat(h, "\n") or "No clears this week yet. Be the first!")
end

function B:Refresh()
    if not win or not win:IsShown() then return end
    local p = win.pages[win.page or "queue"]
    if win.page == "queue" then refreshQueue(p)
    elseif win.page == "party" then refreshParty(p)
    elseif win.page == "tiers" then refreshTiers(p)
    elseif win.page == "rewards" then refreshRewards(p)
    elseif win.page == "armory" then
        local best = 0
        for _, r in ipairs(B.raids) do if r.best > best then best = r.best end end
        p.tier:SetText("Armory gear: |cffffd100tier " .. (best >= 3 and 3 or (best >= 1 and 2 or 1)) .. "|r")
        if p.prep then p.prep:SetText(B.PrepText()) end
    end
    if B.mode then win.foot:SetText("You're in Boss Fights.") else win.foot:SetText("Queue, or go to Gurubashi Arena to gear up first.") end
    if B.mode and not B.run then win.go:Hide() else win.go:Show() end
end

B.TIER_TIP = {
    [2] = "bosses and trash +30% health, +20% damage; Fortified (trash +25%).",
    [3] = "+70% health, +40% damage; Tyrannical (bosses +25%).",
    [4] = "+120% health, +60% damage; Enrage (bosses hit harder the longer a fight lasts).",
    [5] = "+200% health, +80% damage; Fortified and Enrage.",
}

-- -- the raid-ready pop ---------------------------------------------------------------------------

local ready
function B:ShowReady(raid, tier, affixes)
    if not ready then
        ready = UI.Window("BossFightsReady", { width = 300, height = 132, title = "Your raid is ready", icon = ICON, skin = true,
                                               strata = "DIALOG", point = { "TOP", UIParent, "TOP", 0, -160 } })
        ready.what = textLine(ready, "GameFontNormalLarge", 14, -34, 272)
        ready.detail = textLine(ready, "GameFontHighlightSmall", 14, -58, 272)
        ready.go = textLine(ready, "GameFontHighlight", 14, -84, 272)
        ready.bar = UI.Bar and UI.Bar(ready, { width = 272, height = 6 }) or nil
        if ready.bar then ready.bar:SetPoint("BOTTOMLEFT", ready, "BOTTOMLEFT", 14, 12) end
        ready:SetScript("OnUpdate", function()
            local left = (ready.closeAt or 0) - GetTime()
            if left <= 0 then ready:Hide() return end
            if ready.bar and ready.bar.SetMinMaxValues then ready.bar:SetMinMaxValues(0, 10); ready.bar:SetValue(left) end
        end)
    end
    ready.what:SetText(raidName(raid) .. ", Tier " .. (tier or 1))
    local aff = affixText(affixes)
    ready.detail:SetText((aff ~= "" and ("Twist: " .. aff .. " · ") or "") .. "your group's own copy of the raid")
    ready.go:SetText("Taking you in…")
    ready.closeAt = GetTime() + 10
    ready:Show()
    if PlaySound then PlaySound("ReadyCheck") end
end

-- -- the run's timer --------------------------------------------------------------------------------

local hud
local function buildHud()
    hud = CreateFrame("Frame", "BossFightsHud", UIParent)
    hud:SetWidth(230)
    hud:SetHeight(150)
    hud:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -200, -170)
    hud:SetBackdrop(UI.THIN)
    hud:SetBackdropColor(0.03, 0.03, 0.04, 0.82)
    hud:SetBackdropBorderColor(0.6, 0.48, 0.2, 1)
    hud:SetMovable(true)
    hud:EnableMouse(true)
    hud:RegisterForDrag("LeftButton")
    hud:SetScript("OnDragStart", function() hud:StartMoving() end)
    hud:SetScript("OnDragStop", function() hud:StopMovingOrSizing(); W:SavePosition(hud) end)
    hud.title = textLine(hud, "GameFontNormal", 10, -8, 150)
    hud.time = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    hud.time:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -10, -6)
    hud.affix = textLine(hud, "GameFontHighlightSmall", 10, -26, 210)
    hud.stats = textLine(hud, "GameFontHighlightSmall", 10, -42, 210)
    -- realm patch 0062: the ghost split (your best, the record), the boss's health, a reset or countdown coming
    hud.ghost = textLine(hud, "GameFontHighlightSmall", 10, -58, 210)
    hud.note = textLine(hud, "GameFontNormal", 10, -74, 210)
    hud.bosses = textLine(hud, "GameFontHighlightSmall", 10, -92, 210)
    hud.pull = UI.Button(hud, "Pull", 64, 18, function() send("pull") end)
    hud.pull:SetPoint("BOTTOMLEFT", hud, "BOTTOMLEFT", 8, 6)
    hud.reset = UI.Button(hud, "Reset", 64, 18, function() send("reset") end)
    hud.reset:SetPoint("LEFT", hud.pull, "RIGHT", 4, 0)
    hud:Hide()
    B.hud = hud
end

-- ahead (-) or behind (+) a ghost, in seconds: the ghost is paced evenly by the boss's health lost
function B.GhostDelta(elapsed, ghostMs, bossPct)
    if not ghostMs or ghostMs <= 0 then return nil end
    local done = (100 - math.max(0, math.min(100, bossPct or 100))) / 100
    return elapsed - ghostMs / 1000 * done
end

local function signed(sec)
    if not sec then return "" end
    if sec < 0 then return "|cff40ff40-" .. clock(-sec) .. "|r" end
    return "|cffff6040+" .. clock(sec) .. "|r"
end

-- the ready check: Yes / No (the raid leader asked, "rc,<people>")
local rcFrame
function B:ShowReadyCheck(people)
    if not rcFrame then
        rcFrame = UI.Window("BossFightsReadyCheck", { width = 240, height = 96, title = "Ready check", icon = ICON, skin = true,
                                                      strata = "DIALOG", point = { "TOP", UIParent, "TOP", 0, -200 } })
        rcFrame.text = textLine(rcFrame, "GameFontHighlight", 14, -34, 212)
        local y = UI.Button(rcFrame, "I'm ready", 100, 22, function() send("rc yes"); rcFrame:Hide() end)
        y:SetPoint("BOTTOMLEFT", rcFrame, "BOTTOMLEFT", 14, 10)
        local n = UI.Button(rcFrame, "Not ready", 100, 22, function() send("rc no"); rcFrame:Hide() end)
        n:SetPoint("BOTTOMRIGHT", rcFrame, "BOTTOMRIGHT", -14, 10)
    end
    rcFrame.text:SetText("The raid leader is pulling. Ready? (" .. (people or "?") .. " people)")
    rcFrame:Show()
    if PlaySound then PlaySound("ReadyCheck") end
end

function B:RefreshHud()
    local r = B.run
    if not r then if hud then hud:Hide() end return end
    if not hud then buildHud() end
    hud.title:SetText(raidShort(r.raid) .. " · Tier " .. r.tier)
    hud.time:SetText(r.pullAt and clock(GetTime() - r.pullAt) or "0:00")
    local aff = affixText(r.affixes)
    hud.affix:SetText(aff ~= "" and ("|cffff8040" .. aff .. "|r") or "|cff9a9a9ano twist|r")
    if r.twist and r.twist ~= "none" then
        hud.affix:SetText((aff ~= "" and ("|cffff8040" .. aff .. "|r · ") or "") .. "|cffff4060" .. (r.twistTitle or r.twist) .. "|r")
    end
    if r.kind and r.kind ~= "normal" then
        hud.title:SetText(raidShort(r.raid) .. " · Tier " .. r.tier .. " · " .. (B.KIND_LABEL[r.kind] or r.kind))
    end
    hud.stats:SetText("Bosses " .. (r.done or 0) .. "/" .. (r.total or "?") .. "   Deaths " .. (r.deaths or 0) .. "   Wipes " .. (r.wipes or 0) ..
                      ((r.bots or 0) > 0 and ("   |cff80c0ff" .. r.bots .. " bots|r") or ""))
    -- realm patch 0062: the ghost split, live
    local g = {}
    if r.bhp then table.insert(g, "Boss " .. r.bhp .. "%" .. ((r.phase or 0) > 0 and (" P" .. r.phase) or "")) end
    if r.pullAt then
        local el = GetTime() - r.pullAt
        if r.best and r.best > 0 then table.insert(g, "You " .. signed(B.GhostDelta(el, r.best, r.bhp))) end
        if r.record and r.record > 0 then table.insert(g, "Record " .. signed(B.GhostDelta(el, r.record, r.bhp))) end
    elseif r.best or r.record then
        if (r.best or 0) > 0 then table.insert(g, "Best " .. clock(r.best / 1000)) end
        if (r.record or 0) > 0 then table.insert(g, "Record " .. clock(r.record / 1000) .. " (" .. (r.holder or "?") .. ")") end
    end
    hud.ghost:SetText(table.concat(g, "   "))
    local note = ""
    if r.spectator then note = "|cffff6040You fell: watching (hardcore)|r"
    elseif r.resetAt then note = "|cffffd100Reset in " .. math.max(0, math.ceil(r.resetAt - GetTime())) .. " s|r"
    elseif B.countdownAt then
        local left = math.ceil(B.countdownAt - GetTime())
        if left > 0 then note = "|cffff8040Pull in " .. left .. "|r" elseif left > -2 then note = "|cffff4040PULL!|r" end
    end
    hud.note:SetText(note)
    local lines = {}
    local n = getn(r.bosses)
    local first = n > 5 and (n - 4) or 1
    for i = first, n do
        local b = r.bosses[i]
        table.insert(lines, "|cff40ff40" .. b.at .. "|r  " .. b.name)
    end
    hud.bosses:SetText(lines[1] and table.concat(lines, "\n") or (r.pullAt and "" or "The timer starts at the first pull."))
    hud:SetHeight(124 + math.max(1, getn(lines)) * 13)
    hud:Show()
end

-- -- the clear -----------------------------------------------------------------------------------

local done
function B:ShowEnd(cleared, len, deaths, wipes, unlocked, raid, tier)
    if not done then
        done = UI.Window("BossFightsEnd", { width = 340, height = 176, title = "Boss Fights", icon = ICON, skin = true,
                                            strata = "DIALOG", point = { "TOP", UIParent, "TOP", 0, -140 } })
        done.big = done:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        done.big:SetPoint("TOP", done, "TOP", 0, -34)
        done.what = done:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        done.what:SetPoint("TOP", done.big, "BOTTOM", 0, -6)
        done.stats = done:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        done.stats:SetPoint("TOP", done.what, "BOTTOM", 0, -6)
        done.unlock = done:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        done.unlock:SetPoint("TOP", done.stats, "BOTTOM", 0, -6)
        -- realm patch 0062: the meters (damage, healing, deaths), the death recap, the rewards and feats
        done.reward = textLine(done, "GameFontHighlightSmall", 14, -118, 312)
        done.meters = textLine(done, "GameFontHighlightSmall", 14, -150, 312)
        done.recap = textLine(done, "GameFontHighlightSmall", 14, -150, 312)
        done.back = UI.Button(done, "Back to Gurubashi", 132, 22, function() done:Hide(); send("go") end)
        done.back:SetPoint("BOTTOMLEFT", done, "BOTTOMLEFT", 14, 12)
        done.next = UI.Button(done, "Queue the next tier", 132, 22, function()
            done:Hide()
            if done.raid then B.pick.raid, B.pick.tier = done.raid, done.nextTier or 1 end
            B:Queue()
        end)
        done.next:SetPoint("BOTTOMRIGHT", done, "BOTTOMRIGHT", -14, 12)
    end
    done.raid = raid
    if cleared then
        done.big:SetText("|cff40ff40Cleared!|r  " .. len)
        done.unlock:SetText(unlocked and unlocked > (tier or 0) and ("Tier " .. unlocked .. " unlocked") or "")
        done.nextTier = unlocked
        done.next:Show()
    else
        done.big:SetText("|cffff6040The run is over|r")
        done.unlock:SetText("")
        done.next:Hide()
    end
    done.what:SetText(raidName(raid) .. ", Tier " .. (tier or "?"))
    done.stats:SetText("Deaths " .. (deaths or 0) .. " · Wipes " .. (wipes or 0))
    -- realm patch 0062: what came before the end line
    local info = B.endInfo or {}
    B.endInfo = nil
    local rw = {}
    if info.reward then
        if info.reward.scales > 0 then table.insert(rw, "|cffffd100" .. info.reward.scales .. " Dragon Scales|r") end
        if info.reward.egg then table.insert(rw, "|cffff8040a Dragon Egg|r") end
        if info.reward.hoard then table.insert(rw, "a look from the Dragon's Hoard") end
    end
    if info.hatched then table.insert(rw, "|cff40ff40five eggs hatched a whelp!|r") end
    local ft = {}
    for _, f in ipairs(info.feats or {}) do table.insert(ft, B.FEAT_TITLE[f] or f) end
    done.reward:SetText((rw[1] and ("Rewards: " .. table.concat(rw, ", ") .. ". ") or "") .. (ft[1] and ("|cff40ff40Feats: " .. table.concat(ft, ", ") .. "|r") or ""))
    local y = -134
    local ml = {}
    for i, m in ipairs(info.meters or {}) do
        if i <= 10 then
            local col = B.CLASS_COLOR[m.cls] or "ffffff"
            table.insert(ml, "|cff" .. col .. m.name .. "|r" .. (m.bot and " |cff80c0ff(bot)|r" or "") .. "   " .. B.Short(m.damage) .. " dmg   " ..
                             B.Short(m.healing) .. " heal" .. (m.deaths > 0 and ("   |cffff6040" .. m.deaths .. " died|r") or ""))
        end
    end
    done.meters:ClearAllPoints()
    done.meters:SetPoint("TOPLEFT", done, "TOPLEFT", 14, y)
    done.meters:SetText(ml[1] and table.concat(ml, "\n") or "")
    local mh = getn(ml) * 12
    local rl = {}
    for _, h in ipairs(info.recap or {}) do
        table.insert(rl, (h.killing and "|cffff4040" or "|cffd0d0d0") .. h.amount .. "|r  " .. h.what .. "  (" .. h.who .. ")")
    end
    done.recap:ClearAllPoints()
    done.recap:SetPoint("TOPLEFT", done, "TOPLEFT", 14, y - mh - 8)
    done.recap:SetText(rl[1] and ("|cffff8040What killed you:|r\n" .. table.concat(rl, "\n")) or "")
    local rh = rl[1] and ((getn(rl) + 1) * 12 + 8) or 0
    done:SetHeight(176 + mh + rh + (mh > 0 and 8 or 0))
    done:Show()
end

-- -- what the realm says --------------------------------------------------------------------------

-- the queue box's line about bots (realm patch 0054), or the role rule when no bots fill this queue
function B.BotsText(bots)
    if not bots then return "roles: 2 tanks and 2 healers first, then anyone after 2 minutes" end
    local s = bots.state
    if s == "wait" then
        local left = math.max(0, math.floor(bots.at - GetTime() + 0.5))
        if left > 0 then return "bots fill the empty spots in " .. left .. " s" end
        return "bots are on their way"
    elseif s == "joining" then return "|cff80c0ffbots joining: " .. bots.ready .. "/" .. bots.want .. "|r"
    elseif s == "ready" then return "|cff80c0ff" .. bots.want .. " bots in: starting|r"
    elseif s == "full" then return "a raid of people"
    elseif s == "memory" then return "|cffff8040bots unavailable (server busy): waiting for players|r"
    elseif s == "max" then return "|cffff8040bots busy in other raids: waiting for players or free bots|r"
    elseif s == "ai" or s == "off" then return "waiting for players"
    end
    return "|cffff8040bots unavailable: waiting for players|r"
end

local function parseHi(parts)
    B.on = parts[2] == "1"
    B.mode = parts[3] == "1"
    if parts[5] and B.ROLE_LABEL[parts[5]] then B.role = parts[5] end
    B.bonus = tonumber(parts[6]) or 0
    B.raids = {}
    for _, r in ipairs(W.Split(parts[7] or "", ";")) do
        local f = W.Split(r, ":")
        if f[1] and f[1] ~= "" then
            table.insert(B.raids, { key = f[1], best = tonumber(f[2]) or 0, open = tonumber(f[3]) or 1, size = tonumber(f[4]) or 10 })
        end
    end
    if parts[4] and parts[4] ~= "" and not B.pick.raid then B.pick.raid = parts[4] end
    B:ClampTier()
end

function B:OnLine(body)
    local parts = W.Split(body or "", ",")
    local what = parts[1]
    if what == "hi" then
        local was, wasMode = B.on, B.mode
        parseHi(parts)
        if not B.on then
            if win then win:Hide() end
            return
        end
        if not was and W.MicroMenuAdd then W:MicroMenuAdd("Boss Fights", ICON, "BOSSFIGHTS") end
        -- no window on arrival: duelers share this realm and its Gurubashi hangout. It opens from the
        -- site's Fight now (the play page's hint, below), /bf, the micro menu or the realm's "go".
        -- the queue's state, for a character already in Boss Fights (any other is answered "mode")
        if B.mode then send("status") end
        B:ApplyHint()
    elseif what == "go" then
        B.mode = true
        B.ShowBars()
        if parts[2] and parts[2] ~= "" then B.pick.raid = parts[2]; B:ClampTier() end
        B:Show()
    elseif what == "mode" then
        B.mode = parts[2] == "1"
        if B.mode then B.ShowBars() end
        if not B.mode and win then win:Hide() end
        -- "mode,1,0": in Boss Fights but away from the hub (a realm that sends the hub field)
        if B.mode and parts[3] == "0" and B.hintRaid then
            send("go" .. (B.hintRaid ~= "any" and (" " .. B.hintRaid) or ""))
        end
    elseif what == "role" then
        if B.ROLE_LABEL[parts[2] or ""] then B.role = parts[2] end
    elseif what == "ready" then
        -- realm patch 0052: the ready raider (sent when the realm made this character ready, and on "ready"):
        -- key=value pairs after "ready"
        local f = {}
        for i = 2, getn(parts) do
            local _, _, k, v = string.find(parts[i], "^([%a]+)=(.*)$")
            if k then f[k] = v end
        end
        local was = B.prep and B.prep.ok
        B.prep = { level = tonumber(f.level) or 0, spec = string.gsub(f.spec or "?", "_", " "), spent = tonumber(f.spent) or 0,
                   free = tonumber(f.free) or 0, whole = tonumber(f.sets) or 0, sets = tonumber(f.setsof) or 0, worn = f.worn or "-",
                   slots = tonumber(f.slots) or 0, buttons = tonumber(f.buttons) or 0, have = tonumber(f.consumables) or 0,
                   want = tonumber(f.wanted) or 0, missing = f.missing or "-", ok = f.ok == "1" }
        B.mode = true
        B.ShowBars()
        if B.prep.ok and not was and UI.Toast then
            UI.Toast({ icon = ICON, title = "Ready for raids", text = B.prep.spec .. ", level " .. B.prep.level .. ": gear sets in your bags, consumables and bars set.",
                       color = { 0.3, 1, 0.4 } })
        end
    elseif what == "q" then
        -- realm patch 0062: kind= and roulette= ride at the end; take them out first
        local kind, roulette = "normal", false
        local i = getn(parts)
        while i > 1 do
            local _, _, k, v = string.find(parts[i], "^(%a+)=(.*)$")
            if k == "kind" then kind = v; table.remove(parts, i)
            elseif k == "roulette" then roulette = v == "1"; table.remove(parts, i) end
            i = i - 1
        end
        local since = GetTime() - (tonumber(parts[5]) or 0)
        B.queue = { raid = parts[2], tier = tonumber(parts[3]) or 1, queued = tonumber(parts[4]) or 1, since = since, kind = kind, roulette = roulette }
        if parts[9] then
            -- realm patch 0054: the bots for this ticket
            B.queue.bots = { state = parts[9], at = GetTime() + (tonumber(parts[10]) or 0), ready = tonumber(parts[11]) or 0,
                             want = tonumber(parts[12]) or 0 }
        end
        B.mode = true
    elseif what == "fill" then
        B.fill = { on = parts[2] == "1", after = tonumber(parts[3]) or 30 }
    -- ── realm patch 0062 ──
    elseif what == "kinds" then
        B.kinds = { practice = parts[2] == "1", hardcore = parts[3] == "1", story = parts[4] == "1", roulette = parts[5] == "1",
                    reset = tonumber(parts[6]) or 0, storyPeople = tonumber(parts[7]) or 5 }
    elseif what == "week" then
        local text = {}
        for j = 4, getn(parts) do table.insert(text, parts[j]) end
        B.week = { name = parts[2] or "none", title = parts[3] or "", text = table.concat(text, ",") }
    elseif what == "twist" then
        if B.run then
            B.run.twist, B.run.twistTitle, B.run.kind, B.run.roulette = parts[2], parts[3], parts[4] or "normal", parts[5] == "1"
        end
    elseif what == "ghost" then
        if B.run then B.run.best, B.run.record, B.run.holder = tonumber(parts[2]) or 0, tonumber(parts[3]) or 0, parts[4] end
    elseif what == "bhp" then
        if B.run then B.run.bhp, B.run.phase = tonumber(parts[2]), tonumber(parts[3]) or 0 end
    elseif what == "reset" then
        if B.run then
            if parts[2] == "go" then
                B.run.resetAt = nil
                B.countdownAt = nil
                if UI.Toast then UI.Toast({ icon = ICON, title = "Reset", text = "Back at the start, full and buffed. Go again!", color = { 1, 0.82, 0.3 } }) end
            else
                B.run.resetAt = GetTime() + (tonumber(parts[2]) or 10)
            end
        end
    elseif what == "spectate" then
        if B.run then B.run.spectator = true end
    elseif what == "rc" then
        if tonumber(parts[2]) then
            B.rc = { people = tonumber(parts[2]), at = GetTime() }
            B:ShowReadyCheck(parts[2])
        else
            B.rc = nil
            if rcFrame then rcFrame:Hide() end
            local who = parts[3] and string.gsub(parts[3], "%+", ", ") or ""
            say(parts[2] == "no" and (who .. " isn't ready.") or ("Ready check: no answer from " .. (who ~= "" and who or "everyone") .. "."))
        end
    elseif what == "pullin" then
        B.rc = nil
        if rcFrame then rcFrame:Hide() end
        B.countdownAt = GetTime() + (tonumber(parts[2]) or 10)
        if PlaySound then PlaySound("RaidWarning") end
    elseif what == "pullnow" then
        B.countdownAt = GetTime()
    elseif string.sub(body or "", 1, 7) == "meters;" then
        local info = B.endInfo or {}
        info.meters = {}
        local list = W.Split(body, ";")
        for k = 2, getn(list) do
            local f = W.Split(list[k], ":")
            table.insert(info.meters, { name = f[1] or "?", cls = tonumber(f[2]) or 0, role = f[3], damage = tonumber(f[4]) or 0,
                                        healing = tonumber(f[5]) or 0, deaths = tonumber(f[6]) or 0, bot = f[7] == "1" })
        end
        B.endInfo = info
    elseif what == "recap" then
        local recap = {}
        local rest = string.sub(body, 7)
        if rest ~= "-" then
            for _, one in ipairs(W.Split(rest, ";")) do
                local f = W.Split(one, "|")
                table.insert(recap, { who = f[1] or "?", what = f[2] or "?", amount = tonumber(f[3]) or 0, killing = f[4] == "1" })
            end
        end
        B.lastRecap = recap
        local ending = B.endInfo and B.endInfo.meters
        local info = B.endInfo or {}
        info.recap = recap
        B.endInfo = info
        if B.run and recap[1] and not ending and UI.Toast then
            local k = recap[getn(recap)]
            UI.Toast({ icon = ICON, title = "You died", text = k.what .. " from " .. k.who .. " (" .. k.amount .. ")", color = { 1, 0.3, 0.25 } })
        end
    elseif what == "reward" then
        local info = B.endInfo or {}
        info.reward = { scales = tonumber(parts[2]) or 0, egg = parts[3] == "1", hoard = (tonumber(parts[4]) or 0) > 0 }
        info.feats = (parts[5] and parts[5] ~= "none") and W.Split(parts[5], "+") or {}
        B.endInfo = info
        B.scales = (B.scales or 0) + info.reward.scales
    elseif what == "hatched" then
        local info = B.endInfo or {}
        info.hatched = true
        B.endInfo = info
        if UI.Toast then UI.Toast({ icon = ICON, title = "Hatched!", text = "Five Dragon Eggs hatched a Dark Whelpling.", color = { 0.4, 1, 0.4 } }) end
    elseif what == "feat" then
        if UI.Toast then UI.Toast({ icon = ICON, title = "Feat: " .. (parts[3] or parts[2] or ""), text = "Boss Fights", color = { 1, 0.82, 0.3 } }) end
    elseif what == "horn" then
        if parts[2] == "sent" then
            say("The Rally Horn sounds in Gurubashi (" .. (parts[3] or 0) .. " heard it).")
        elseif UI.Toast then
            local text = {}
            for j = 2, getn(parts) do table.insert(text, parts[j]) end
            UI.Toast({ icon = ICON, title = "Rally Horn", text = table.concat(text, ","), color = { 1, 0.6, 0.2 } })
        end
    elseif string.sub(body or "", 1, 5) == "shop;" then
        local list = W.Split(body, ";")
        B.scales = tonumber(list[2]) or 0
        B.shop = {}
        for k = 3, getn(list) do
            local f = W.Split(list[k], ":")
            if tonumber(f[1]) then
                table.insert(B.shop, { item = tonumber(f[1]), price = tonumber(f[2]) or 0, name = f[3] or "?", have = f[4] == "1" })
            end
        end
    elseif what == "shop" then
        if parts[2] == "bought" then
            B.scales = tonumber(parts[4]) or B.scales
            send("shop")
        end
    elseif string.sub(body or "", 1, 6) == "feats;" or body == "feats" then
        B.feats = {}
        local list = W.Split(body, ";")
        for k = 2, getn(list) do
            local f = W.Split(list[k], ":")
            if f[1] and f[1] ~= "" then table.insert(B.feats, { key = f[1], count = tonumber(f[2]) or 1 }) end
        end
    elseif string.sub(body or "", 1, 4) == "hof;" or body == "hof" then
        B.hof = {}
        local list = W.Split(body, ";")
        for k = 2, getn(list) do
            local f = W.Split(list[k], ":")
            if f[1] and f[1] ~= "" then
                -- the clock itself has a colon: raid:tier:m:ss:leader[:bots]
                local n = getn(f)
                local bots = f[n] == "bots"
                if bots then n = n - 1 end
                local tm = {}
                for j = 3, n - 1 do table.insert(tm, f[j]) end
                table.insert(B.hof, { raid = f[1], tier = tonumber(f[2]) or 1, time = table.concat(tm, ":"), leader = f[n] or "?", bots = bots })
            end
        end
    elseif what == "rbots" then
        if B.run then B.run.bots = tonumber(parts[2]) or 0 end
    elseif what == "unq" or what == "idle" then
        B.queue = nil
    elseif what == "requeue" then
        B.queue = nil
        if UI.Toast then UI.Toast({ icon = ICON, title = "Boss Fights", text = "Someone in your raid wasn't ready: queue again.", color = { 1, 0.5, 0.25 } }) end
    elseif string.sub(body or "", 1, 4) == "lfg;" or body == "lfg" then
        B.posts = {}
        local list = W.Split(body, ";")
        local k = 2
        while list[k] do
            local f = W.Split(list[k], ",")
            local need = W.Split(f[6] or "", ":")
            -- the note may carry commas
            local note = {}
            local j = 7
            while f[j] do table.insert(note, f[j]); j = j + 1 end
            table.insert(B.posts, { id = f[1], raid = f[2], tier = tonumber(f[3]) or 1, leader = f[4] or "?", size = tonumber(f[5]) or 1,
                                    t = tonumber(need[1]) or 0, h = tonumber(need[2]) or 0, d = tonumber(need[3]) or 0,
                                    note = table.concat(note, ",") })
            k = k + 1
        end
    elseif what == "lfg" then
        if parts[2] == "posted" or parts[2] == "dropped" or parts[2] == "joined" then send("lfg") end
        if parts[2] == "member" and UI.Toast then
            UI.Toast({ icon = ICON, title = "Party search", text = (parts[3] or "Someone") .. " is joining your party.", color = { 1, 0.82, 0.3 } })
        end
    elseif string.sub(body or "", 1, 6) == "tiers;" or body == "tiers" then
        local list = W.Split(body, ";")
        local k = 2
        while list[k] do
            local f = W.Split(list[k], ",")
            local r = raidInfo(f[1])
            if r then r.best, r.open = tonumber(f[2]) or r.best, tonumber(f[3]) or r.open end
            k = k + 1
        end
        local best = 0
        for _, r in ipairs(B.raids) do if r.best > best then best = r.best end end
        B.bonus = math.min(10, best * 2)
        B:ClampTier()
    elseif what == "board" then
        local list = W.Split(body, ";")
        local head = W.Split(list[1] or "", ",")
        B.board = { raid = head[2], tier = tonumber(head[3]) or 1, rows = {} }
        local k = 2
        while list[k] do
            local f = W.Split(list[k], ",")
            table.insert(B.board.rows, { time = f[1] or "?", leader = f[2] or "?", size = f[3] or "?", ended = tonumber(f[4]) or 0 })
            k = k + 1
        end
    elseif what == "pop" then
        B.queue = nil
        B.run = { id = parts[2], raid = parts[3], tier = tonumber(parts[4]) or 1, affixes = parts[5] or "none", bosses = {}, deaths = 0, wipes = 0, done = 0 }
        B:ShowReady(parts[3], parts[4], parts[5])
        if win then win:Hide() end
    elseif what == "in" then
        if not B.run or B.run.id ~= parts[2] then
            B.run = { id = parts[2], raid = parts[3], tier = tonumber(parts[4]) or 1, affixes = "none", bosses = {}, deaths = 0, wipes = 0, done = 0 }
        end
        B.run.size = tonumber(parts[5]) or B.run.size
        send("status")
    elseif what == "pull" then
        if B.run and not B.run.pullAt then B.run.pullAt = GetTime() end
    elseif what == "boss" then
        if B.run then
            table.insert(B.run.bosses, { name = parts[3] or "?", at = parts[4] or "" })
            B.run.done = getn(B.run.bosses)
            if UI.Toast then UI.Toast({ icon = ICON, title = (parts[3] or "Boss") .. " down", text = (parts[4] or "") .. " into the run", color = { 0.4, 1, 0.4 } }) end
        end
    elseif what == "wipe" then
        if B.run then B.run.wipes = tonumber(parts[2]) or (B.run.wipes + 1) end
    elseif what == "run" then
        -- run,<id>,<raid>,<tier>,<m:ss>,<done>/<total>
        if not B.run or B.run.id ~= parts[2] then
            B.run = { id = parts[2], raid = parts[3], tier = tonumber(parts[4]) or 1, affixes = "none", bosses = {}, deaths = 0, wipes = 0, done = 0 }
        end
        local since = seconds(parts[5])
        if since > 0 then B.run.pullAt = GetTime() - since end
        local dt = W.Split(parts[6] or "", "/")
        B.run.done, B.run.total = tonumber(dt[1]) or B.run.done, tonumber(dt[2]) or B.run.total
    elseif what == "end" then
        B.countdownAt = nil
        B.rc = nil
        if rcFrame then rcFrame:Hide() end
        local r = B.run or {}
        B:ShowEnd(parts[2] == "1", parts[3] or "?", tonumber(parts[4]) or 0, tonumber(parts[5]) or 0, tonumber(parts[6]), r.raid, r.tier)
        B.result = body
        B.run = nil
        send("tiers")
    elseif what == "left" then
        B.run = nil
    elseif what == "err" then
        -- the realm says why in chat; a refused queue is no longer a queue
        if parts[2] == "queue" then B.queue = nil end
    end
    B:RefreshHud()
    B:Refresh()
end

-- -- the site's hint ------------------------------------------------------------------------------
-- The Boss Fights page links to the play page with ?mode=boss&raid=<raid>. The play page keeps that for
-- the tab (it survives sign-in and the character screen) and, once in the world, hands it here:
-- WenillaCore:Dispatch("BFH", "<raid>") (realm/www/openvanilla.js, warfrontMode). Applied once, after
-- the realm's hello: the window opens on the Queue tab with that raid picked, the realm is told the
-- character plays Boss Fights ("mode boss"), and a character not in Boss Fights is taken to Gurubashi.

function B:ApplyHint()
    if not B.hint or not B.on then return end
    local raid = B.hint
    B.hint = nil
    B.hintRaid = raid
    if raid ~= "any" and raidInfo(raid) then B.pick.raid = raid; B:ClampTier() end
    B:Show()
    if win.tabs and win.tabs.Select then win.tabs:Select("queue") else B:ShowPage("queue") end
    send("mode boss")
    if not B.mode and not B.run then
        send("go" .. ((raid ~= "any" and raidInfo(raid)) and (" " .. raid) or ""))
    end
end

function OpenVanillaModeHint(mode, raid)
    if mode ~= "boss" then return end
    raid = string.lower(W.Trim(raid or ""))
    if raid == "" then raid = "any" end
    B.hint = raid
    B:ApplyHint()                            -- before the realm's hello this only keeps it
end

W:RegisterModule("BFH", function(body) OpenVanillaModeHint("boss", body) end)

W:RegisterModule("BF", function(body)
    local ok, err = pcall(B.OnLine, B, body)
    if not ok then W.Print("|cffff4040Boss Fights:|r " .. tostring(err)) end
end)

-- Warfront's hello ("WF 1,...") means the realm runs a Warfront world server: ask whether it runs Boss Fights.
local prevWF = W.modules and W.modules["WF"]
W:RegisterModule("WF", function(body)
    if prevWF then prevWF(body) end
    local parts = W.Split(body or "", ",")
    if parts[1] == "1" then
        B.wfHello = true
        W:SendCommand("wf", "bf hi")
    end
end)

-- The realm's answer to "bf hi" turns the addon on. It can be missed (a busy first load: the hello came
-- while the game was still loading, 2026-10-23), and then the window never opened and Queue up did nothing.
-- So after entering the world, ask again every 8 s, four times at most, while the addon is still off and
-- either Warfront's hello came or the site sent this tab here for Boss Fights (the play page's hint).
local hiAsk = CreateFrame("Frame", "BossFights_HiAsk")
local hiLeft, hiTries = 0, 0
hiAsk:RegisterEvent("PLAYER_ENTERING_WORLD")
hiAsk:SetScript("OnEvent", function() hiLeft, hiTries = 8, 0 end)
hiAsk:SetScript("OnUpdate", function()
    if B.on or hiTries >= 4 or hiLeft <= 0 then return end
    hiLeft = hiLeft - (arg1 or 0)
    if hiLeft > 0 then return end
    hiTries = hiTries + 1
    hiLeft = (hiTries < 4) and 8 or 0
    if B.wfHello or B.hint then W:SendCommand("wf", "bf hi") end
end)

-- deaths in the raid (the realm counts them too, and sends the total at the end)
local ev = CreateFrame("Frame", "BossFights_Events")
ev:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLY_DEATH")
ev:RegisterEvent("PLAYER_DEAD")
ev:SetScript("OnEvent", function()
    if not B.run then return end
    if event == "PLAYER_DEAD" or (event == "CHAT_MSG_COMBAT_FRIENDLY_DEATH" and arg1 and not string.find(arg1, "^You die")) then
        B.run.deaths = (B.run.deaths or 0) + 1
        B:RefreshHud()
    end
end)

-- the timers: the run's clock, the queue's clock, and the realm's view every 15 s
local tick = CreateFrame("Frame", "BossFights_Tick")
local acc, sync = 0, 0
tick:SetScript("OnUpdate", function()
    if not B.on then return end
    local e = arg1 or 0
    acc = acc + e
    sync = sync + e
    if acc >= 0.5 then
        acc = 0
        if B.run then B:RefreshHud() end
        if B.queue or B.run then B:Refresh() end
    end
    if sync >= 15 then
        sync = 0
        if B.queue or B.run then send("status") end
    end
end)

SLASH_BOSSFIGHTS1 = "/bf"
SLASH_BOSSFIGHTS2 = "/bossfights"
SlashCmdList["BOSSFIGHTS"] = function(msg)
    msg = string.lower(W.Trim(msg or ""))
    if msg == "" then B:Toggle()
    elseif msg == "go" then send("go")
    elseif msg == "leave" or msg == "unq" then send("unq")
    elseif msg == "abandon" then send("abandon")
    elseif msg == "status" then send("status")
    elseif msg == "ready" then send("ready")
    elseif msg == "tiers" then send("tiers")
    elseif msg == "duels" then send("duels")
    -- realm patch 0062
    elseif msg == "pull" then send("pull")
    elseif msg == "reset" then send("reset")
    elseif msg == "yes" or msg == "no" then send("rc " .. msg)
    elseif msg == "horn" then send("horn")
    elseif msg == "shop" then send("shop")
    elseif msg == "feats" then send("feats")
    elseif msg == "hof" then send("hof")
    elseif string.sub(msg, 1, 1) == "q" then
        local p = W.Split(W.Trim(string.sub(msg, 2)), " ")
        if p[1] and p[1] ~= "" then B.pick.raid = p[1] end
        if p[2] then B.pick.tier = tonumber(p[2]) or B.pick.tier end
        -- realm patch 0062: /bf q onyxia 2 hardcore; /bf q roulette
        if p[1] == "roulette" then B.pick.kind = "roulette"
        elseif p[3] and B.KIND_LABEL[p[3]] then B.pick.kind = p[3]
        else B.pick.kind = "normal" end
        B:Queue()
    else
        say("/bf opens the window; /bf q <raid> [tier] [practice2|practice3|hardcore|story] queues (onyxia, mc, any, roulette); /bf leave; /bf go (Gurubashi); /bf abandon leaves a raid; /bf ready checks your gear, bags and bars; /bf pull, /bf reset (raid leader); /bf yes|no (ready check); /bf horn; /bf shop; /bf feats; /bf hof; /bf duels.")
    end
end

BINDING_HEADER_BOSSFIGHTS = "Boss Fights"
