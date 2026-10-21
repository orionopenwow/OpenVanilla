--[[
    MicroMenu.lua  (Open Vanilla)
    The menu bar beside the action bar, laid out as modern World of Warcraft's, so every window the
    suite adds has one home and the bar never grows a button per addon:

        Character  Professions  Talents & Spellbook  Achievements  Quest Log
        Guild & Communities  Group Finder  Collections  Adventure Guide  Game Menu

    Several of those open a "hub": windows that share stock-style tabs along their bottom, the way
    retail's Group Finder or Collections switch pages. A tab hides the window you're in and opens
    the next one in the same place:

        Talents & Spellbook   Spellbook | Talents | Planner (Talents addon)
        Guild & Communities   Guild (Guild Hub) | Guild Finder | Friends
        Group Finder          Dungeons & Raids | Player vs. Player (Warfront realms)
        Collections           Mounts | Pets | Appearances (Transmog realms)

    Help moves into the Game Menu (Support), with Edit Mode (Move Anything), AddOns and the Open
    Vanilla tools list (meters, threat, bags, raid tools, Persona, Assistant, Herald, Workshop...).
    A button whose feature is off (no Achievements, no Dungeons) hides and the bar closes up.

    Addons join with W:MicroMenuAdd(label, icon, slashKey, arg): "Appearances" becomes the
    Collections tab, "Warfront" the Group Finder's PvP tab, anything else a tools row.
    Art: WenillaCore/Media/Micro<Name>.tga (tools/gen_micro_menu.py). Lua 5.0 rules.
]]--

local W = WenillaCore
local UI = W.UI
local MM = {}
W.MicroMenu = MM

local getn, tinsert = table.getn, table.insert

local function slash(key, arg)
    return function()
        local f = SlashCmdList and SlashCmdList[key]
        if f then f(arg or "") return true end
    end
end
local function hasSlash(key) return function() return SlashCmdList and SlashCmdList[key] and true or false end end
local function frame(name) return name and getglobal(name) end
local function shown(name) local f = frame(name); return f and f:IsVisible() end
local function active(id) return W:IsActive(id) and true or false end

-- -- Hubs ----------------------------------------------------------------------------------------
-- hub = { entries = { { key, label, frame, open, avail, panel } }, last = key }
-- frame: the window's global name; open(): shows it; avail(): offered now; panel: a stock UI
-- panel (the client places it; we only follow it with the tabs).

MM.hubs = {}
local HUB_ORDER = { "spells", "guild", "finder", "collections" }

function MM:HubAdd(hub, e)
    local h = self.hubs[hub]
    if not h then h = { entries = {} }; self.hubs[hub] = h end
    for i, x in ipairs(h.entries) do
        if x.key == e.key then h.entries[i] = e; return e end
    end
    tinsert(h.entries, e)
    return e
end

local function avail(e) return not e.avail or e.avail() end

function MM:HubEntries(hub)
    local out = {}
    for _, e in ipairs((self.hubs[hub] or {}).entries or {}) do if avail(e) then tinsert(out, e) end end
    return out
end

-- The entry of a hub whose window is on screen now.
function MM:HubShown(hub)
    for _, e in ipairs(self:HubEntries(hub)) do if shown(e.frame) then return e end end
end

-- Open a hub: its last page if it's still offered, else the first (or `prefer`).
function MM:OpenHub(hub, prefer)
    local list = self:HubEntries(hub)
    if getn(list) == 0 then return false end
    local cur = self:HubShown(hub)
    if cur and not prefer then          -- the button again closes it, as retail's do
        local f = frame(cur.frame)
        if cur.panel and HideUIPanel then HideUIPanel(f) else f:Hide() end
        return true
    end
    local want = prefer or (self.hubs[hub] and self.hubs[hub].last)
    local pick = list[1]
    for _, e in ipairs(list) do if e.key == want then pick = e end end
    self:CloseOtherHubs(hub)
    return self:Switch(hub, pick.key)
end

-- One hub at a time: the hubs' own windows all open in the middle of the screen, so Guild &
-- Communities over Collections showed both at once, mixed together (a player's report, 2026-10-21).
-- A stock panel (the spellbook, Friends) is left to the client, which lines panels up side by side.
function MM:CloseOtherHubs(keep)
    for _, other in ipairs(HUB_ORDER) do
        if other ~= keep then
            local cur = self:HubShown(other)
            if cur and not cur.panel then
                local f = frame(cur.frame)
                if f then f:Hide() end
            end
        end
    end
end

-- Switch a hub to a page: hide the window on screen, open the other in its place.
function MM:Switch(hub, key)
    local h = self.hubs[hub]
    if not h then return false end
    local target
    for _, e in ipairs(self:HubEntries(hub)) do if e.key == key then target = e end end
    if not target then return false end
    local cur = self:HubShown(hub)
    local x, y
    if cur and cur.key ~= key then
        local f = frame(cur.frame)
        if not cur.panel then x, y = f:GetLeft(), f:GetTop() end
        if cur.panel and HideUIPanel then HideUIPanel(f) else f:Hide() end
    end
    h.last = key
    if not (cur and cur.key == key) then target.open() end
    local f = frame(target.frame)
    if f and x and y and not target.panel and f:IsVisible() then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    end
    MM:UpdateTabs()
    return true
end

-- One strip of stock bottom tabs per hub, under whichever of its windows is open.
local strips = {}
local function strip(hub)
    if strips[hub] then return strips[hub] end
    local holder = CreateFrame("Frame", "OVHubTabs_" .. hub, UIParent)
    holder:SetWidth(10)
    holder:SetHeight(32)
    holder:Hide()
    local bar = UI.ClassicTabs(holder, { onSelect = function(key) MM:Switch(hub, key) end })
    bar:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    holder.bar = bar
    strips[hub] = holder
    return holder
end
MM.Strip = strip

function MM:UpdateTabs()
    for _, hub in ipairs(HUB_ORDER) do
        local cur = self:HubShown(hub)
        local list = self:HubEntries(hub)
        local s = strips[hub]
        if cur and getn(list) > 1 then
            s = strip(hub)
            local tabs, sig = {}, ""
            for _, e in ipairs(list) do tinsert(tabs, { key = e.key, label = e.label }); sig = sig .. e.key .. "," end
            if s.sig ~= sig then s.bar:SetTabs(tabs); s.sig = sig end
            if s.bar:Selected() ~= cur.key then s.bar:Select(cur.key, true) end
            local f = frame(cur.frame)
            s:SetParent(f)
            s:SetFrameStrata(f:GetFrameStrata())
            s:SetFrameLevel(f:GetFrameLevel() + 4)
            s:ClearAllPoints()
            -- a stock panel's own bottom tabs (spell schools, talent trees, Friends/Who/Guild):
            -- ours go on after the last one showing
            local last
            for _, n in ipairs(cur.after or {}) do local t = frame(n); if t and t:IsShown() then last = t end end
            -- a suite window with its own bottom tabs (UI.ClassicFrame: the Guild Hub's six pages)
            if not last and f.tabs and f.tabs.bottomTabs and f.tabs.buttons and f.tabs ~= s.bar then
                for _, t in ipairs(f.tabs.buttons) do if t:IsShown() then last = t end end
            end
            if last then
                s:SetPoint("TOPLEFT", last, "TOPRIGHT", 6, 0)    -- a small gap: the hub's tabs are a group of their own
            elseif cur.panel then       -- the stock panels draw their tab row 78 px above the frame's foot
                s:SetPoint("TOPLEFT", f, "BOTTOMLEFT", cur.tabX or 15, cur.tabY or 78)
            else
                -- a window in the Classic frame (UI.ClassicChrome): the tabs hang from the frame art
                local base = (f.chrome and f.chrome:IsShown()) and f.chrome or f
                s:SetPoint("TOPLEFT", base, "BOTTOMLEFT", cur.tabX or 11, cur.tabY or 4)
            end
            s:Show()
        elseif s then
            s:Hide()
        end
    end
end

-- the windows open and close from many places (keys, slash commands, other addons): follow them
local watch = CreateFrame("Frame", "OVMicroMenu_Watch")
local watchT = 0
watch:SetScript("OnUpdate", function()
    watchT = watchT + (arg1 or 0)
    if watchT < 0.15 then return end
    watchT = 0
    MM:UpdateTabs()
    -- a feature switched on or off (in /addons, or an addon loading late): re-lay the bar
    if MM.built then
        local sig = ""
        for _, d in ipairs(MM.ORDER) do sig = sig .. ((d.avail and not d.avail()) and "0" or "1") end
        if sig ~= MM.availSig then MM.availSig = sig; MM:Layout() end
    end
end)

-- The hubs the suite knows. Addons that load later or only on some realms make their entries
-- available through their own signals (W:MicroMenuAdd).
MM.realmOffers = {}

MM:HubAdd("spells", { key = "spellbook", label = "Spellbook", frame = "SpellBookFrame", panel = true,
    after = { "SpellBookFrameTabButton1", "SpellBookFrameTabButton2", "SpellBookFrameTabButton3" },
    open = function() ToggleSpellBook(BOOKTYPE_SPELL or "spell") end })
MM:HubAdd("spells", { key = "talents", label = "Talents", frame = "TalentFrame", panel = true,
    after = { "TalentFrameTab1", "TalentFrameTab2", "TalentFrameTab3", "TalentFrameTab4", "TalentFrameTab5" },
    open = function() if ToggleTalentFrame then ToggleTalentFrame() end end,
    avail = function() return (UnitLevel("player") or 1) >= 10 end })
MM:HubAdd("spells", { key = "planner", label = "Planner", frame = "Talents_Planner",
    open = slash("CPTALENTS", "plan"), avail = function() return hasSlash("CPTALENTS")() and active("Talents") end })

MM:HubAdd("guild", { key = "guild", label = "My Guild", frame = "GuildHub_Frame", open = slash("GUILDHUB"),
    avail = function() return hasSlash("GUILDHUB")() and active("GuildHub") and IsInGuild and IsInGuild() end })
MM:HubAdd("guild", { key = "finder", label = "Guild Finder", frame = "Concord_Frame", open = slash("GUILDS"),
    avail = function() return hasSlash("GUILDS")() and active("Guilds") end })
MM:HubAdd("guild", { key = "friends", label = "Friends", frame = "Social_Frame", open = slash("SOCIAL"),
    avail = function() return hasSlash("SOCIAL")() and active("Social") end })
MM:HubAdd("guild", { key = "stockfriends", label = "Friends", frame = "FriendsFrame", panel = true,
    after = { "FriendsFrameTab1", "FriendsFrameTab2", "FriendsFrameTab3", "FriendsFrameTab4" },
    open = function() ToggleFriendsFrame() end,
    avail = function() return not (hasSlash("SOCIAL")() and active("Social")) end })

MM:HubAdd("finder", { key = "pve", label = "Dungeons & Raids", frame = "Dungeons_Frame",
    open = function() if Dungeons and Dungeons.Show then Dungeons:Show("browse") else slash("DUNGEONS", "browse")() end end,
    avail = function() return hasSlash("DUNGEONS")() and active("Dungeons") end })
MM:HubAdd("finder", { key = "pvp", label = "Player vs. Player", frame = "WarfrontFrame", open = slash("WARFRONT"),
    avail = function() return MM.realmOffers.Warfront and hasSlash("WARFRONT")() end })

MM:HubAdd("collections", { key = "mounts", label = "Mounts", frame = "OVCollectionsFrame", tabY = 4,
    open = function() MM.Collections:Show("mounts") end })
MM:HubAdd("collections", { key = "pets", label = "Pets", frame = "OVCollectionsFrame", tabY = 4,
    open = function() MM.Collections:Show("pets") end })
-- always a tab when the Transmog addon is on; on a realm without transmog the window says so
MM:HubAdd("collections", { key = "appearances", label = "Appearances", frame = "TransmogFrame", tabX = 44, tabY = 10,
    open = slash("TRANSMOG"), avail = function() return hasSlash("TRANSMOG")() and active("Transmog") end })

-- Mounts and Pets share one window: tell the hub which page is up.
local baseShown = MM.HubShown
function MM:HubShown(hub)
    local e = baseShown(self, hub)
    if e and e.frame == "OVCollectionsFrame" and MM.Collections then
        for _, x in ipairs(self:HubEntries(hub)) do if x.key == MM.Collections.page then return x end end
    end
    return e
end

-- -- Tools: everything that isn't a modern menu button --------------------------------------
-- label, icon, slash key, argument
MM.tools = {
    { "Meters",        "Interface\\Icons\\Ability_Warrior_SavageBlow",      "METERS" },
    { "Threat",        "Interface\\Icons\\Ability_Warrior_DefensiveStance", "THREAT" },
    { "Bags",          "Interface\\Icons\\INV_Misc_Bag_10",                 "BAGS" },
    { "Raid tools",    "Interface\\Icons\\Ability_Warrior_BattleShout",     "RALLY" },
    { "Persona",       "Interface\\Icons\\INV_Misc_Book_09",                "PERSONA" },
    { "Minimap ring",  "Interface\\Icons\\INV_Misc_Map_01",                 "QUESTS", "theme" },
    { "Workshop",      "Interface\\Icons\\INV_Misc_Note_01",                "CPWORKSHOP" },
    { "Herald",        "Interface\\Icons\\INV_Misc_Head_Dwarf_01",          "HERALD" },
    { "Assistant",     "Interface\\Icons\\INV_Misc_Note_02",                "ASSISTANT" },
    { "Key Ring",      "Interface\\Icons\\INV_Misc_Key_14",                 "OVKEYRING" },
    { "All AddOns",    "Interface\\Icons\\INV_Misc_Gear_01",                "CPADDONS" },
}

-- Another addon joins the menu: W:MicroMenuAdd("Warfront", icon, "WARFRONT"). The labels the
-- modern layout has a home for go there; anything else becomes a tools row.
function W:MicroMenuAdd(label, icon, slashKey, arg)
    if label == "Appearances" or label == "Warfront" then
        MM.realmOffers[label] = true
        MM:Layout()
        return
    end
    for _, e in ipairs(MM.tools) do if e[1] == label then return end end
    tinsert(MM.tools, getn(MM.tools), { label, icon, slashKey, arg })
    if MM.toolsPanel then MM.toolsPanel:Rebuild() end
end

-- -- The buttons ---------------------------------------------------------------------------------

local function bindingText(action)
    local key = action and GetBindingKey and GetBindingKey(action)
    return key and (" |cffffd100(" .. key .. ")|r") or ""
end

local function tip(b)
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    GameTooltip:SetText(b.ovTitle .. bindingText(b.ovBinding), 1, 1, 1)
    if b.ovText then GameTooltip:AddLine(b.ovText, 1, 0.82, 0, 1) end
    if b.ovTipExtra then b.ovTipExtra() end
    GameTooltip:Show()
end

-- The latency, in the Game Menu button's tooltip as retail shows it: the stock latency bar's own
-- hover button sat on top of this button and took its clicks (see MM:Latency).
local function latencyLines()
    local _, _, ms = GetNetStats()
    ms = ms or 0
    local r, g = 0.2, 1
    if ms > 600 then r, g = 1, 0.2 elseif ms > 300 then r, g = 1, 1 end
    GameTooltip:AddLine("Latency: " .. ms .. " ms", r, g, 0.2)
    if GetFramerate then
        GameTooltip:AddLine("Frame rate: " .. math.floor(GetFramerate() + 0.5) .. " fps", 0.8, 0.8, 0.8)
    end
end

-- A new button that is a stock micro button: the client's own empty frame (the one the Character
-- button puts your portrait in) with our emblem on it, pressed in the way the portrait is.
local FRAME_UP = "Interface\\Buttons\\UI-MicroButtonCharacter-Up"
local FRAME_DOWN = "Interface\\Buttons\\UI-MicroButtonCharacter-Down"

local function newButton(name, art, fallbackIcon)
    local b = CreateFrame("Button", name, MainMenuBarArtFrame or UIParent)
    b:SetWidth(28)
    b:SetHeight(58)
    b:SetNormalTexture(FRAME_UP)
    b:SetPushedTexture(FRAME_DOWN)
    local em = b:CreateTexture(name .. "Emblem", "OVERLAY")
    em:SetWidth(28)
    em:SetHeight(58)
    if not W:Art(em, art, nil) then        -- no emblem art: the icon in the face
        em:SetTexture(fallbackIcon)
        em:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        em:SetWidth(20)
        em:SetHeight(25)
        b.emblemY = -29
    end
    b.emblem = em
    local function place(down)
        em:ClearAllPoints()
        em:SetPoint("TOP", b, "TOP", down and -1 or 0, (b.emblemY or 0) - (down and 2 or 0))
        if down then em:SetVertexColor(0.65, 0.65, 0.65) else em:SetVertexColor(1, 1, 1) end
    end
    place(false)
    b:SetScript("OnMouseDown", function() if this:IsEnabled() then place(true) end end)
    b:SetScript("OnMouseUp", function() place(false) end)
    b:SetScript("OnHide", function() place(false) end)
    b:SetHighlightTexture("Interface\\Buttons\\UI-MicroButton-Hilight")
    local hl = b:GetHighlightTexture()
    if hl and hl.SetBlendMode then hl:SetBlendMode("ADD") end
    return b
end

-- The modern order. stock = a client button we keep (and may give a new job); new = ours.
MM.ORDER = {
    { stock = "CharacterMicroButton", title = "Character Info", binding = "TOGGLECHARACTER0" },
    { new = "OVProfessionsMicroButton", art = "MicroProfessions", icon = "Interface\\Icons\\Trade_BlackSmithing",
      title = "Professions", binding = "OV_PROFESSIONS", text = "Your professions and their windows.",
      click = function() MM.Professions:Toggle() end },
    { stock = "SpellbookMicroButton", title = "Talents & Spellbook", binding = "TOGGLESPELLBOOK",
      text = "Your spells and talents.", click = function() MM:OpenHub("spells") end },
    { new = "OVAchievementsMicroButton", art = "MicroAchievements", icon = "Interface\\Icons\\INV_Crown_01",
      title = "Achievements", binding = "ACHIEVEMENTS_TOGGLE", click = slash("ACHIEVEMENTS"),
      avail = function() return hasSlash("ACHIEVEMENTS")() and active("Achievements") end },
    { stock = "QuestLogMicroButton", title = "Map & Quest Log", binding = "TOGGLEQUESTLOG" },
    { stock = "SocialsMicroButton", title = "Guild & Communities", binding = "OV_GUILD",
      text = "Your guild, the guild finder and your friends.", click = function() MM:OpenHub("guild") end },
    { new = "OVGroupFinderMicroButton", art = "MicroGroupFinder", icon = "Interface\\Icons\\INV_Misc_Spyglass_02",
      title = "Group Finder", binding = "OV_GROUPFINDER", text = "Dungeons, raids and battles: find a group.",
      click = function() MM:OpenHub("finder") end,
      avail = function() return getn(MM:HubEntries("finder")) > 0 end },
    { new = "OVCollectionsMicroButton", art = "MicroCollections", icon = "Interface\\Icons\\Ability_Mount_RidingHorse",
      title = "Collections", binding = "OV_COLLECTIONS", text = "Mounts, pets and appearances.",
      click = function() MM:OpenHub("collections") end },
    { new = "OVAdventureGuideMicroButton", art = "MicroAdventureGuide", icon = "Interface\\Icons\\INV_Misc_Book_11",
      title = "Adventure Guide", binding = "OV_ADVENTUREGUIDE", text = "Dungeons and raids for your level.",
      click = function() MM.Guide:Toggle() end,
      avail = function() return Dungeons and Dungeons.LIST and true or false end },
    { stock = "MainMenuMicroButton", title = "Game Menu", binding = "TOGGLEGAMEMENU", tipExtra = latencyLines },
}
-- Stock buttons the modern bar folds away: talents live with the spellbook, the map with the
-- quest log, Help in the Game Menu.
MM.RETIRED = { "TalentMicroButton", "WorldMapMicroButton", "HelpMicroButton" }

MM.buttons = {}

local function makeAll()
    for _, d in ipairs(MM.ORDER) do
        local b
        if d.stock then
            b = frame(d.stock)
        else
            b = frame(d.new) or newButton(d.new, d.art, d.icon)
        end
        if b then
            b.ovTitle, b.ovText, b.ovBinding, b.ovTipExtra = d.title, d.text, d.binding, d.tipExtra
            if d.click then b:SetScript("OnClick", d.click) end
            b:SetScript("OnEnter", function() tip(this) end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            d.button = b
            tinsert(MM.buttons, b)
        end
    end
end



function MM:Layout()
    if not self.built then return end
    W:GameMenuShow("GameMenuButtonOVEditMode", hasSlash("CPMOVE")())
    for _, n in ipairs(self.RETIRED) do local b = frame(n); if b then b:Hide() end end
    for _, d in ipairs(self.ORDER) do
        local b = d.button
        if b then
            if d.avail and not d.avail() then b:Hide() else b:Show() end
        end
    end
    self:KeyRing()
    self:Latency()
    if self.placer then                                          -- another layout owns the bar
        if self.cover then self.cover:Hide() end
        self.placer(self:Visible())
        return
    end

    self:Fit()
end

-- -- Where the bar goes ---------------------------------------------------------------------
-- The 1.12 bar's menu recess (x 548-766) holds the stock eight buttons. Ten at the stock size and
-- the stock 3 px overlap need 253 px, so the recess runs on over the key ring's slot (to x 806,
-- where the bags begin) and the key ring button goes (see MM:KeyRing):
--
--   [ action bar ][ Character ... Adventure Guide  Game Menu ][bag][bag][bag][bag][backpack]
-- The recess over the key ring's slot is the bar's own texture (the player's client file).

local BAR_ART = "Interface\\MainMenuBar\\UI-MainMenuBar-Dwarf"
MM.SLOT_LEFT, MM.SLOT_RIGHT = 546, 806      -- where the stock Character button sits; where the bags begin
MM.OVERLAP = 3                              -- the stock buttons' overlap (their textures have a soft edge)
MM.BOTTOM = 2                               -- the stock buttons' y on the bar
MM.FACE = 38                                -- a button's face height (lower 42 of 64 texture rows, on 58 px)

-- The recess laid over the key ring's slot (x 766-806).
function MM:Cover()
    if self.cover then return self.cover end
    local art = MainMenuBarArtFrame
    if not art then return end
    local c = CreateFrame("Frame", "OVMicroMenuRecess", art)
    c:SetFrameLevel(art:GetFrameLevel())
    c:SetWidth(self.SLOT_RIGHT - 766)
    c:SetHeight(43)
    c:SetPoint("BOTTOMLEFT", art, "BOTTOMLEFT", 766, 0)
    local t = c:CreateTexture(nil, "ARTWORK")
    t:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)
    t:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -16, 0)
    t:SetTexture(BAR_ART)
    t:SetTexCoord(200 / 256, 230 / 256, 0.33203125, 0.5)      -- plain recess from near its end
    local cap = c:CreateTexture(nil, "ARTWORK")                 -- and the recess's own right end
    cap:SetWidth(16)
    cap:SetHeight(43)
    cap:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 0)
    cap:SetTexture(BAR_ART)
    cap:SetTexCoord(238 / 256, 254 / 256, 0.33203125, 0.5)
    self.cover = c
    return c
end

-- No key ring button on the bar (retail has none). Keys still go to the key ring by themselves; it
-- opens with /keyring or from the Game Menu's Open Vanilla list. The client shows the button again
-- now and then, so it's kept hidden.
function MM:KeyRing()
    local kr = frame("KeyRingButton")
    if not kr then return end
    kr:Hide()
    if not kr.ovHidden then
        kr.ovHidden = true
        local onShow = kr:GetScript("OnShow")
        kr:SetScript("OnShow", function()
            if onShow then onShow() end
            this:Hide()
        end)
    end
end

-- No stock latency bar either. MainMenuBar.xml puts it at the bar's x 781-797 with a HIGH-strata
-- hover button over it, and that is where the Game Menu button sits now: the hover button covered
-- the button, so a click there showed the latency instead of opening the menu (a player's report,
-- 2026-10-21). Its slot is under our recess anyway. The latency is in the Game Menu's tooltip.
function MM:Latency()
    for _, n in ipairs({ "MainMenuBarPerformanceBarFrameButton", "MainMenuBarPerformanceBarFrame" }) do
        local f = frame(n)
        if f then
            if f.EnableMouse then f:EnableMouse(false) end
            f:Hide()
            if not f.ovHidden then
                f.ovHidden = true
                local onShow = f:GetScript("OnShow")
                f:SetScript("OnShow", function()
                    if onShow then onShow() end
                    this:Hide()
                end)
            end
        end
    end
end

function MM:ToggleKeyRing()
    if ToggleKeyRing then ToggleKeyRing() return true end
    W.Print("This client has no key ring.")
end
SLASH_OVKEYRING1 = "/keyring"
SLASH_OVKEYRING2 = "/keys"
SlashCmdList["OVKEYRING"] = function() MM:ToggleKeyRing() end

function MM:Fit()
    local list = self:Visible()
    local n = getn(list)
    if n == 0 then return end
    local art = MainMenuBarArtFrame or UIParent
    if self:Cover() then self.cover:Show() end
    self:KeyRing()
    local avail = self.SLOT_RIGHT - self.SLOT_LEFT
    local scale = 1
    local need = 28 * n - self.OVERLAP * (n - 1)
    if need > avail then scale = math.max(0.6, (avail + self.OVERLAP * (n - 1)) / (28 * n)) end
    local step = 28 * scale - self.OVERLAP
    local y = self.BOTTOM + (1 - scale) * self.FACE / 2
    self.scale, self.step = scale, step
    for i, b in ipairs(list) do
        b:SetScale(scale)
        b:ClearAllPoints()
        -- a point's offsets are in the button's own scale
        b:SetPoint("BOTTOMLEFT", art, "BOTTOMLEFT", (self.SLOT_LEFT + (i - 1) * step) / scale, y / scale)
    end
end

-- The client re-anchors its own buttons now and then (1.12's UpdateMicroButtons shows the Talents
-- button again at level 10 and hangs the Quest Log button on it): put the bar back after it.
if type(UpdateMicroButtons) == "function" then
    local stockUpdate = UpdateMicroButtons
    UpdateMicroButtons = function(a1, a2, a3)
        stockUpdate(a1, a2, a3)
        if MM.built then MM:Layout() end
    end
end

-- A UI layout that puts the bar somewhere else (the UI Repack) hands in placer(buttons): it's
-- called with the visible buttons, left to right, whenever they change.
function MM:SetPlacer(fn)
    self.placer = fn
    self:Layout()
end

-- The bar as it stands, left to right (the UI Repack lays these out in its own strip).
function MM:Visible()
    local out = {}
    for _, d in ipairs(self.ORDER) do
        if d.button and d.button:IsShown() then tinsert(out, d.button) end
    end
    return out
end

-- -- Key bindings (Bindings.xml) and their first-run keys --------------------------------------
BINDING_HEADER_OPENVANILLA_MENU = "Open Vanilla menu"
BINDING_NAME_OV_PROFESSIONS = "Professions"
BINDING_NAME_OV_GUILD = "Guild & Communities"
BINDING_NAME_OV_GROUPFINDER = "Group Finder"
BINDING_NAME_OV_COLLECTIONS = "Collections"
BINDING_NAME_OV_ADVENTUREGUIDE = "Adventure Guide"
function OpenVanilla_Professions() MM.Professions:Toggle() end
function OpenVanilla_Guild() MM:OpenHub("guild") end
function OpenVanilla_GroupFinder() MM:OpenHub("finder") end
function OpenVanilla_Collections() MM:OpenHub("collections") end
function OpenVanilla_AdventureGuide() MM.Guide:Toggle() end

-- retail's keys, each only when it's free (Shift-P stays the pet spellbook's)
MM.DEFAULT_KEYS = { { "K", "OV_PROFESSIONS" }, { "J", "OV_GUILD" }, { "I", "OV_GROUPFINDER" }, { "SHIFT-J", "OV_ADVENTUREGUIDE" } }
function MM:DefaultBindings()
    local cfg = WenillaCore_Config
    if type(cfg) ~= "table" or cfg.menuKeys or not (SetBinding and GetBindingAction) then return end
    cfg.menuKeys = true
    local changed
    for _, k in ipairs(self.DEFAULT_KEYS) do
        local cur = GetBindingAction(k[1])
        if (not GetBindingKey or not GetBindingKey(k[2])) and (not cur or cur == "") then
            if SetBinding(k[1], k[2]) then changed = true end
        end
    end
    if changed and SaveBindings then SaveBindings(GetCurrentBindingSet and GetCurrentBindingSet() or 1) end
end

-- -- The Game Menu: Support, Edit Mode, Open Vanilla tools ------------------------------------

local function hookGameMenu()
    W:GameMenuAdd("GameMenuButtonOVEditMode", "Edit Mode", function() slash("CPMOVE")() end, 20)
    W:GameMenuAdd("GameMenuButtonOVTools", "Open Vanilla", function() MM:ToggleTools() end, 30)
    W:GameMenuAdd("GameMenuButtonOVSupport", "Support", function() if ToggleHelpFrame then ToggleHelpFrame() end end, 40)
end

-- The tools list: a small window with a row per tool.
function MM:ToggleTools()
    local p = self.toolsPanel
    if not p then
        p = UI.Window("OVToolsFrame", { width = 250, height = 60, title = "Open Vanilla",
            icon = "Interface\\Icons\\INV_Misc_Gear_01", point = { "CENTER", UIParent, "CENTER", 0, 60 }, skin = true, strata = "DIALOG" })
        p:Hide()
        if UISpecialFrames then tinsert(UISpecialFrames, "OVToolsFrame") end
        p.rows = {}
        function p:Rebuild()
            local n = 0
            for _, e in ipairs(MM.tools) do
                local entry = e
                n = n + 1
                local row = self.rows[n]
                if not row then
                    row = CreateFrame("Button", nil, self)
                    row:SetHeight(24)
                    row:SetPoint("TOPLEFT", self, "TOPLEFT", 12, -34 - (n - 1) * 26)
                    row:SetPoint("TOPRIGHT", self, "TOPRIGHT", -12, -34 - (n - 1) * 26)
                    row.bg = row:CreateTexture(nil, "BACKGROUND")
                    row.bg:SetAllPoints(row)
                    row.bg:SetTexture(1, 1, 1, 0.035)
                    local box = UI.IconBox(row, 20)
                    box:SetPoint("LEFT", row, "LEFT", 2, 0)
                    row.icon = box.icon
                    row.text = UI.Label(row, 11, { 1, 0.82, 0 })
                    row.text:SetPoint("LEFT", box, "RIGHT", 8, 0)
                    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
                    self.rows[n] = row
                end
                row.icon:SetTexture(entry[2])
                row.text:SetText(entry[1])
                row:SetScript("OnClick", function()
                    p:Hide()
                    if not slash(entry[3], entry[4])() then W.Print(entry[1] .. " is not loaded.") end
                end)
                row:Show()
            end
            for i = n + 1, getn(self.rows) do self.rows[i]:Hide() end
            self:SetHeight(n * 26 + 46)
        end
        p:Rebuild()
        self.toolsPanel = p
    end
    if p:IsShown() then p:Hide() else p:Show() end
end

-- -- Startup ---------------------------------------------------------------------------------------

function MM:Build()
    if self.built then return end
    self.built = true
    makeAll()
    self:Layout()
    hookGameMenu()
end

local ev = CreateFrame("Frame", "OVMicroMenu_Events")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("VARIABLES_LOADED")
ev:RegisterEvent("PLAYER_GUILD_UPDATE")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then MM:DefaultBindings() end
    MM:Build()
    MM:Layout()
end)
MM:Build()
