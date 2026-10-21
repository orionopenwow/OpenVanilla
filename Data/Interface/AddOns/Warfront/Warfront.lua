--[[
    Warfront.lua  (Open Vanilla / Warfront realm)
    The Warfront window: level 60 kits, the gear picker with enchants, the consumables shop and
    gear sets shared across the realm. Arena.lua adds the arena tab.

    It asks the realm ".wnl wf hi" once telemetry is up. Only a realm running Warfront answers
    "WF 1,..."; anywhere else the addon stays hidden and does nothing.
    Server lines: WF WK WS WE WP WB WH WL WV WR WN WC WG (see the world server's OpenVanilla/Warfront.h).
    Lua 5.0 rules: no #, no %, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Warfront"
local ICON = "Interface\\Icons\\INV_BannerPVP_02"

Warfront = Warfront or {}
local F = Warfront

local strfind, strsub, strlower, format = string.find, string.sub, string.lower, string.format
local getn = table.getn

F.on = false              -- the realm said WF 1
F.tier = 0
F.kills = 0
F.best = 0
F.asked = false

-- equipment slots as the server numbers them (0-based) with their names
F.SLOTS = {
    { 0, "Head" }, { 1, "Neck" }, { 2, "Shoulders" }, { 14, "Back" }, { 4, "Chest" }, { 8, "Wrist" },
    { 9, "Hands" }, { 5, "Waist" }, { 6, "Legs" }, { 7, "Feet" }, { 10, "Finger 1" }, { 11, "Finger 2" },
    { 12, "Trinket 1" }, { 13, "Trinket 2" }, { 15, "Main hand" }, { 16, "Off hand" }, { 17, "Ranged" },
}

local REASON = {
    off = "Warfront is not running on this realm.", combat = "Not in combat.", dead = "Not while dead.",
    busy = "One moment, still working on the last change.", instance = "Not inside an arena, battleground or dungeon.",
    queue = "Leave the queue first.", key = "That kit doesn't exist.", class = "That isn't for your class.",
    faction = "That kit is for the other faction.", tier = "Locked: earn it with arena rating or honorable kills.",
    slot = "That doesn't go in that slot.", item = "That item can't be picked here.", bags = "Your bags are full.",
    enchant = "That enchant isn't offered for this slot.", money = "Not enough gold.", name = "Give the set a name.",
    full = "You have shared 10 sets already. Remove one first.", gone = "That set is no longer shared.",
    self = "You can't vote for or report your own set.", voted = "You already did that for this set.",
    skill = "Your character can't use that weapon type yet. Try again in a few seconds.",
    twohand = "Your main hand is a two-handed weapon.", faction2 = "",
}

local function say(msg) W.Print("|cffff8040Warfront:|r " .. msg) end
F.Say = say

local function reason(code) return REASON[code or ""] or ("Refused (" .. tostring(code) .. ").") end
F.Reason = reason

local function toast(title, text, color)
    if UI.Toast then UI.Toast({ icon = ICON, title = title, text = text or "", color = color or { 1, 0.5, 0.25 } }) end
end
F.Toast = toast

local function active() return W:IsActive(ID) end

local function send(args)
    if not F.on then return nil end
    return W:SendCommand("wf", args)
end
F.Send = send

local function myClass()
    local _, c = UnitClass("player")
    return c or ""
end

local function myFaction()
    local f = UnitFactionGroup and UnitFactionGroup("player")
    return f or "Alliance"
end

local function itemName(id)
    local name = GetItemInfo and GetItemInfo(id)
    return name or ("Item " .. tostring(id))
end
F.ItemName = itemName

local function linkId(link)
    if not link then return nil end
    local _, _, id = strfind(link, "item:(%d+)")
    return id and tonumber(id)
end

-- -- the window -------------------------------------------------------------------------------

local win, tabs
local pages = {}
F.pages = pages

local function status(text)
    if win and win.status then win.status:SetText(text or "") end
end
F.Status = status

local function makePage(key)
    local p = CreateFrame("Frame", nil, win)
    p:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -54)
    p:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 30)
    p:Hide()
    pages[key] = p
    return p
end

function F:Select(key)
    for k, p in pairs(pages) do
        if k == key then p:Show() else p:Hide() end
    end
    F.current = key
    if F.onSelect and F.onSelect[key] then F.onSelect[key]() end
end

F.onSelect = {}
F.tabList = { { key = "kits", label = "Kits" }, { key = "gear", label = "Gear" }, { key = "shop", label = "Shop" }, { key = "sets", label = "Shared sets" } }

function F:Build()
    if win then return win end
    win = UI.Window("WarfrontFrame", { classicFrame = true, width = 470, height = 420, title = "Warfront", icon = ICON, skin = true })
    win:Hide()
    F.win = win
    if UISpecialFrames then table.insert(UISpecialFrames, "WarfrontFrame") end
    local tier = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tier:SetPoint("TOPRIGHT", win, "TOPRIGHT", -12, -30)
    win.tierText = tier
    local st = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    st:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 12, 10)
    st:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -12, 10)
    st:SetJustifyH("LEFT")
    win.status = st
    tabs = UI.Tabs(win, { tabs = F.tabList, onSelect = function(k) F:Select(k) end })
    tabs:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -26)
    win.tabs = tabs
    for _, t in ipairs(F.tabList) do
        if F.builders[t.key] then F.builders[t.key](makePage(t.key)) end
    end
    F:Select("kits")
    F:UpdateTier()
    return win
end

function F:UpdateTier()
    if not win then return end
    local t = F.tier >= 3 and "|cffa335eeTier 3 unlocked|r" or F.tier >= 2 and "|cff0070ddTier 2 unlocked|r" or "|cff1eff00Starter tier|r"
    win.tierText:SetText(t .. "  |cff9d9d9d" .. F.kills .. " kills, best rating " .. F.best .. "|r")
end

function F:Toggle(key)
    if not F.on then
        say("Warfront's window works on the Warfront realm only.")
        return
    end
    F:Build()
    if win:IsShown() and (not key or key == F.current) then win:Hide() return end
    win:Show()
    if key then
        if tabs and tabs.Select then tabs:Select(key) end
        F:Select(key)
    end
end

F.builders = {}

-- -- Kits -------------------------------------------------------------------------------------

local function myKits()
    local list = {}
    local c, fa = myClass(), myFaction()
    for _, k in ipairs(WarfrontKits or {}) do
        if k.class == c and k.faction == fa then table.insert(list, k) end
    end
    return list
end
F.MyKits = myKits

F.builders.kits = function(p)
    local head = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    head:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -2)
    head:SetPoint("TOPRIGHT", p, "TOPRIGHT", -2, -2)
    head:SetJustifyH("LEFT")
    head:SetText("Pick a kit: the full epic PvP set, the rest of the slots from Molten Core, Blackwing Lair and Zul'Gurub, enchanted. Change any piece later in Gear.")
    p.head = head
    p.cards = {}
    for i = 1, 3 do
        local card = CreateFrame("Frame", nil, p)
        card:SetHeight(92)
        card:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -34 - (i - 1) * 100)
        card:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, -34 - (i - 1) * 100)
        card:SetBackdrop(UI.THIN)
        card:SetBackdropColor(0.1, 0.1, 0.12, 0.9)
        card:SetBackdropBorderColor(0.4, 0.35, 0.25, 1)
        local t = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -8)
        card.title = t
        local d = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -6)
        d:SetPoint("RIGHT", card, "RIGHT", -120, 0)
        d:SetJustifyH("LEFT")
        card.desc = d
        local b = UI.Button(card, "Equip kit", 100, 22, function()
            if card.kit then F:EquipKit(card.kit.key) end
        end)
        b:SetPoint("RIGHT", card, "RIGHT", -10, 0)
        card.button = b
        card:Hide()
        p.cards[i] = card
    end
    p.none = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.none:SetPoint("TOP", p, "TOP", 0, -60)
    F.onSelect.kits = function() F:FillKits() end
end

function F:FillKits()
    local p = pages.kits
    if not p then return end
    local kits = myKits()
    for i, card in ipairs(p.cards) do
        local k = kits[i]
        card.kit = k
        if k then
            card.title:SetText(k.spec .. "  |cff9d9d9d" .. k.role .. "|r")
            local main = k.items[16] and itemName(k.items[16]) or ""
            local off = k.items[17] and itemName(k.items[17]) or nil
            local rng = k.items[18] and itemName(k.items[18]) or nil
            local line = main
            if off then line = line .. " + " .. off end
            if rng then line = line .. ";  " .. rng end
            local n = 0
            for _ in pairs(k.items) do n = n + 1 end
            local e = 0
            for _ in pairs(k.enchants or {}) do e = e + 1 end
            card.desc:SetText(line .. "\n" .. n .. " items, " .. e .. " enchants")
            card:Show()
        else
            card:Hide()
        end
    end
    if kits[1] then p.none:SetText("") else p.none:SetText("No kit for your class and faction on Warfront.") end
end

function F:EquipKit(key)
    if send("kit " .. key) then
        F.pendingKit = key
        status("Equipping " .. key .. "...")
    end
end

W:RegisterModule("WK", function(body)
    local parts = W.Split(body, ",")
    if parts[1] == "ok" then
        local what = parts[2] or ""
        if strsub(what, 1, 3) == "set" then
            status("Applied a shared set: " .. (parts[3] or 0) .. " items on, " .. (parts[4] or 0) .. " skipped (locked or not for you).")
            toast("Set applied", (parts[3] or 0) .. " items equipped.")
        else
            status("Kit equipped: " .. (parts[3] or 0) .. " items, " .. (parts[4] or 0) .. " enchants.")
            toast("Kit equipped", "Ready for the fight.")
        end
        F.pendingKit = nil
    else
        status("|cffff4040" .. reason(parts[2]) .. "|r")
    end
end)

-- -- Gear ---------------------------------------------------------------------------------------

F.builders.gear = function(p)
    p.slotButtons = {}
    for i, s in ipairs(F.SLOTS) do
        local slot, label = s[1], s[2]
        local b = UI.Button(p, label, 92, 18, function() F:PickSlot(slot) end)
        local col = i <= 9 and 0 or 1
        local row = i <= 9 and i - 1 or i - 10
        b:SetPoint("TOPLEFT", p, "TOPLEFT", col * 96, -row * 20)
        p.slotButtons[slot] = b
    end
    local head = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    head:SetPoint("TOPLEFT", p, "TOPLEFT", 196, -2)
    head:SetText("Pick a slot")
    p.head = head
    p.list = UI.ScrollList(p, {
        name = "WarfrontGearList", width = 254, height = 196, rowHeight = 16,
        build = function(row)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.text:SetJustifyH("LEFT")
            row:SetScript("OnClick", function() if row.item then F:PickItem(row.item) end end)
        end,
        update = function(row, item)
            row.item = item
            local locked = item.tier > F.tier
            row.text:SetText((locked and "|cff808080" or "") .. itemName(item.id) .. (locked and ("  (tier " .. item.tier .. ")|r") or ""))
        end,
    })
    p.list:SetPoint("TOPLEFT", p, "TOPLEFT", 196, -18)
    p.enchHead = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.enchHead:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -186)
    p.enchHead:SetText("Enchant")
    p.ench = UI.ScrollList(p, {
        name = "WarfrontEnchantList", width = 190, height = 112, rowHeight = 16,
        build = function(row)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.text:SetJustifyH("LEFT")
            row:SetScript("OnClick", function() if row.ench then F:PickEnchant(row.ench[1]) end end)
        end,
        update = function(row, e)
            row.ench = e
            row.text:SetText(e[2])
        end,
    })
    p.ench:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -200)
end

F.pools = {}

function F:PickSlot(slot)
    F.slot = slot
    local p = pages.gear
    local label = ""
    for _, s in ipairs(F.SLOTS) do if s[1] == slot then label = s[2] end end
    p.head:SetText(label .. ": click an item to wear it")
    p.enchHead:SetText(label .. " enchant")
    local list = {}
    for _, e in ipairs((WarfrontEnchants or {})[slot + 1] or {}) do table.insert(list, e) end
    p.ench:SetItems(list)
    if F.pools[slot] then
        p.list:SetItems(F.pools[slot])
    else
        p.list:SetItems({})
        status("Loading the items for this slot...")
        send("pool " .. slot)
    end
end

function F:PickItem(item)
    if item.tier > F.tier then
        status("|cffff4040" .. reason("tier") .. "|r")
        return
    end
    if send("slot " .. F.slot .. " " .. item.id) then status("Equipping " .. itemName(item.id) .. "...") end
end

function F:PickEnchant(spell)
    if send("ench " .. F.slot .. " " .. spell) then status("Enchanting...") end
end

W:RegisterModule("WP", function(body)
    local parts = W.Split(body, ";")
    local slot = tonumber(parts[1])
    if not slot then
        status("|cffff4040" .. reason(parts[2]) .. "|r")
        return
    end
    local list = {}
    for i = 2, getn(parts) do
        local _, _, id, tier = strfind(parts[i], "^(%d+),(%d+)$")
        if id then table.insert(list, { id = tonumber(id), tier = tonumber(tier) }) end
    end
    -- unlocked first, then by name
    table.sort(list, function(a, b)
        local la, lb = a.tier > F.tier, b.tier > F.tier
        if la ~= lb then return lb end
        return itemName(a.id) < itemName(b.id)
    end)
    F.pools[slot] = list
    if pages.gear and F.slot == slot then pages.gear.list:SetItems(list) end
    status(getn(list) .. " items for this slot.")
end)

W:RegisterModule("WS", function(body)
    local parts = W.Split(body, ",")
    if parts[1] == "ok" then status(itemName(tonumber(parts[3]) or 0) .. " equipped.")
    else status("|cffff4040" .. reason(parts[2]) .. "|r") end
end)

W:RegisterModule("WE", function(body)
    local parts = W.Split(body, ",")
    if parts[1] == "ok" then status("Enchanted.")
    else status("|cffff4040" .. reason(parts[2]) .. "|r") end
end)

-- -- Shop ---------------------------------------------------------------------------------------

F.builders.shop = function(p)
    local head = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    head:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -2)
    head:SetText("Click to buy one; Shift-click to buy a stack.")
    p.list = UI.ScrollList(p, {
        name = "WarfrontShopList", width = 448, height = 300, rowHeight = 16,
        build = function(row)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.text:SetJustifyH("LEFT")
            row.price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.price:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            row:SetScript("OnClick", function()
                if not row.entry then return end
                local n = (IsShiftKeyDown and IsShiftKeyDown()) and row.entry[3] or 1
                F:Buy(row.entry[1], n)
            end)
        end,
        update = function(row, e)
            row.entry = e
            row.text:SetText(e[4])
            row.price:SetText(UI.CoinText and UI.CoinText(e[2]) or (e[2] .. "c"))
        end,
    })
    p.list:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -18)
    p.list:SetItems(WarfrontShop or {})
end

function F:Buy(item, count)
    if send("buy " .. item .. " " .. (count or 1)) then status("Buying...") end
end

W:RegisterModule("WB", function(body)
    local parts = W.Split(body, ",")
    if parts[1] == "ok" then status("Bought " .. (parts[3] or 1) .. " x " .. itemName(tonumber(parts[2]) or 0) .. ".")
    else status("|cffff4040" .. reason(parts[2]) .. "|r") end
end)

-- -- Shared sets --------------------------------------------------------------------------------

F.builders.sets = function(p)
    local function box(label, x, w, max)
        local l = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        l:SetPoint("TOPLEFT", p, "TOPLEFT", x, -2)
        l:SetText(label)
        local e = CreateFrame("EditBox", nil, p)
        e:SetWidth(w)
        e:SetHeight(18)
        e:SetPoint("TOPLEFT", l, "BOTTOMLEFT", 0, -2)
        e:SetAutoFocus(false)
        e:SetMaxLetters(max)
        e:SetFontObject(GameFontHighlightSmall)
        e:SetBackdrop(UI.THIN)
        e:SetBackdropColor(0, 0, 0, 0.8)
        e:SetScript("OnEscapePressed", function() this:ClearFocus() end)
        e:SetScript("OnEnterPressed", function() this:ClearFocus() end)
        return e
    end
    p.name = box("Set name", 0, 150, 24)
    p.spec = box("Spec", 160, 100, 24)
    local share = UI.Button(p, "Share my gear", 110, 20, function() F:ShareCurrent(p.name:GetText(), p.spec:GetText()) end)
    share:SetPoint("TOPLEFT", p, "TOPLEFT", 270, -14)
    local refresh = UI.Button(p, "Refresh", 70, 20, function() F:LoadSets() end)
    refresh:SetPoint("LEFT", share, "RIGHT", 4, 0)
    p.list = UI.ScrollList(p, {
        name = "WarfrontSetList", width = 448, height = 270, rowHeight = 22,
        build = function(row)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.text:SetPoint("RIGHT", row, "RIGHT", -170, 0)
            row.text:SetJustifyH("LEFT")
            row.apply = UI.Button(row, "Apply", 52, 18, function() if row.set then F:ApplySet(row.set.id) end end)
            row.apply:SetPoint("RIGHT", row, "RIGHT", -112, 0)
            row.vote = UI.Button(row, "Vote", 48, 18, function() if row.set then send("vote " .. row.set.id) end end)
            row.vote:SetPoint("LEFT", row.apply, "RIGHT", 2, 0)
            row.report = UI.Button(row, "Report", 56, 18, function() if row.set then send("report " .. row.set.id) end end)
            row.report:SetPoint("LEFT", row.vote, "RIGHT", 2, 0)
        end,
        update = function(row, s)
            row.set = s
            row.text:SetText(s.name .. "  |cff9d9d9d" .. s.spec .. ", by " .. s.owner .. ", " .. s.votes .. " votes|r")
        end,
    })
    p.list:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -46)
    F.onSelect.sets = function() if not F.setsLoaded then F:LoadSets() end end
end

-- the gear on now, as "<slot>:<item>,..." (server slots)
function F:CurrentGear()
    local out = {}
    for _, s in ipairs(F.SLOTS) do
        local id = linkId(GetInventoryItemLink("player", s[1] + 1))
        if id then table.insert(out, s[1] .. ":" .. id) end
    end
    return table.concat(out, ",")
end

local function clean(s)
    s = s or ""
    s = string.gsub(s, "[^%w %-']", "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

function F:ShareCurrent(name, spec)
    name, spec = clean(name), clean(spec)
    if name == "" then status("|cffff4040" .. reason("name") .. "|r") return end
    if spec == "" then spec = "PvP" end
    local gear = F:CurrentGear()
    if gear == "" then status("|cffff4040Put some gear on first.|r") return end
    if send("share " .. spec .. "~" .. name .. "~" .. gear) then status("Sharing...") end
end

function F:LoadSets()
    if send("sets") then
        F.setsLoaded = true
        status("Loading shared sets...")
    end
end

function F:ApplySet(id)
    if send("apply " .. id) then status("Applying set " .. id .. "...") end
end

W:RegisterModule("WH", function(body)
    local parts = W.Split(body, ",")
    if parts[1] == "ok" then
        F:LoadSets()
        status("Shared. Other players can now find and apply your set.")
        toast("Set shared", "It's in the realm's shared sets.")
    else
        status("|cffff4040" .. reason(parts[2]) .. "|r")
    end
end)

W:RegisterModule("WL", function(body)
    local list = {}
    if body ~= "-" then
        for _, rec in ipairs(W.Split(body, ";")) do
            local f = W.Split(rec, ",")
            if f[1] and tonumber(f[1]) then
                table.insert(list, { id = tonumber(f[1]), votes = tonumber(f[2]) or 0, owner = f[3] or "?", spec = f[4] or "", name = f[5] or "", items = f[6] or "" })
            end
        end
    end
    F.sets = list
    if pages.sets then pages.sets.list:SetItems(list) end
    status(getn(list) == 0 and "No shared sets for your class yet. Be the first." or (getn(list) .. " shared sets for your class."))
end)

W:RegisterModule("WV", function(body)
    local parts = W.Split(body, ",")
    if parts[1] == "ok" then
        status("Voted.")
        for _, s in ipairs(F.sets or {}) do if s.id == tonumber(parts[2]) then s.votes = tonumber(parts[3]) or s.votes end end
        if pages.sets then pages.sets.list:Refresh() end
    else
        status("|cffff4040" .. reason(parts[2]) .. "|r")
    end
end)

W:RegisterModule("WR", function(body)
    local parts = W.Split(body, ",")
    if parts[1] == "ok" then status("Reported. Three reports hide a set until staff look at it.")
    else status("|cffff4040" .. reason(parts[2]) .. "|r") end
end)

-- -- bounties -----------------------------------------------------------------------------------

W:RegisterModule("WN", function(body)
    local parts = W.Split(body, ",")
    if parts[1] == "streak" then
        say("|cffff2020" .. (parts[2] or "?") .. " is on a " .. (parts[3] or "?") .. "-kill streak in " .. (parts[4] or "the zone") .. ". Bounty on their head!|r")
    elseif parts[1] == "ended" then
        say("|cffffd100" .. (parts[2] or "?") .. "'s " .. (parts[3] or "?") .. "-kill streak is over. No bounty was paid.|r")
    elseif parts[1] == "paid" then
        toast("Bounty collected", (parts[2] or "?") .. ": " .. (parts[3] or 0) .. " gold.", { 1, 0.82, 0 })
    end
end)

-- -- the realm says hello -----------------------------------------------------------------------

local MODE_START   -- the website's mode choices (below)

W:RegisterModule("WF", function(body)
    local parts = W.Split(body, ",")
    if parts[1] ~= "1" then
        F.on = false
        if win then win:Hide() end
        return
    end
    local first = not F.on
    F.on = true
    F.tier = tonumber(parts[2]) or 0
    F.kills = tonumber(parts[3]) or 0
    F.best = tonumber(parts[4]) or 0
    F:UpdateTier()
    if first and W.MicroMenuAdd then W:MicroMenuAdd("Warfront", ICON, "WARFRONT") end
    if parts[5] == "1" then
        -- the character's first login: open on the kits (the mode they chose comes after a kit)
        F:Build()
        win:Show()
        F:Select("kits")
        local after = F.wantMode and MODE_START[F.wantMode] and (" Then: " .. MODE_START[F.wantMode].line) or ""
        toast("Welcome to Warfront", "Pick a kit to start. Your mount, bags and supplies are in your bags." .. after)
        F.wantMode = nil
    elseif F.wantMode then
        F:ApplyMode(F.wantMode)
    end
end)

-- -- the mode chosen on the website ---------------------------------------------------------------
-- openvanilla.js passes the website's Warfront mode screen choice (?mode=) as WM once in the world.
MODE_START = {
    arena = { tab = "arena", title = "Arena", line = "Pick a queue here, or type /arena d1 (1v1), /arena s2 (2v2 skirmish), /arena r2 (rated)." },
    bg = { tab = "arena", title = "Battlegrounds", line = "Talk to a Battlemaster in your capital. Warsong Gulch starts at 6; when your side is full you play for the other." },
    duels = { title = "Duels and bounties", line = "Head to the Gurubashi Arena in Stranglethorn Vale: duels there reset you, kill streaks carry a bounty, a chest spawns on the hour." },
    kits = { tab = "kits", title = "Gear up", line = "Pick a kit for your class, then swap pieces on the Gear tab and buy flasks in the Shop." },
}
F.MODE_START = MODE_START

function F:ApplyMode(mode)
    local m = MODE_START[mode]
    F.wantMode = nil
    if not m then return end
    if m.tab then
        F:Build()
        win:Show()
        if win.tabs and win.tabs.Select then win.tabs:Select(m.tab) end
        F:Select(m.tab)
    end
    toast(m.title, m.line)
    say(m.line)
end

W:RegisterModule("WM", function(body)
    local mode = W.Trim(body or "")
    if not MODE_START[mode] then return end
    if F.on then F:ApplyMode(mode) else F.wantMode = mode end   -- before the realm says hello: keep it
end)

local poll = CreateFrame("Frame", "Warfront_Poll")
poll:SetScript("OnUpdate", function()
    if F.asked or not W.connected or not active() then return end
    F.asked = true
    W:SendCommand("wf", "hi")
    poll:Hide()
end)

-- -- registration -------------------------------------------------------------------------------

W:RegisterSchema(ID, {
    title = "Warfront",
    icon = ICON,
    desc = "The Warfront realm's window: kits, gear picker, enchants, consumables, shared sets and the arena queue. Hidden on other realms.",
    defaults = {},
    options = {},
})

W:RegisterAddon(ID, function(on)
    if not on and win then win:Hide() end
end)

SLASH_WARFRONT1 = "/wf"
SLASH_WARFRONT2 = "/warfront"
SLASH_WARFRONT3 = "/kit"
SlashCmdList["WARFRONT"] = function(msg)
    if not active() then return end
    msg = strlower(W.Trim(msg or ""))
    if msg == "" then F:Toggle()
    elseif msg == "kits" or msg == "gear" or msg == "shop" or msg == "sets" or msg == "arena" then F:Toggle(msg)
    else say("/wf opens the window; /wf kits|gear|shop|sets|arena opens a tab.") end
end
