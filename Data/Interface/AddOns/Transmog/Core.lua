--[[
    Core.lua  (Open Vanilla / Transmog)
    Transmogrification the way retail has it since Midnight: looks collected account-wide, saved
    to OUTFITS (one per gear slot set, not per item), switched for free anywhere, saved at a
    Transmogrifier for gold. The realm decides everything (src/game/OpenVanilla/Transmog.h); this
    file keeps what it said: outfits, the collection, illusions, sets and custom sets.

    Also here: the tooltip lines ("You haven't collected this appearance"), /outfit, chat links
    for custom sets, and the toasts when a new look is collected.
    Server lines: TM (see Transmog.h). Lua 5.0 rules: no #, no %, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Transmog"
local ICON = "Interface\\Icons\\INV_Chest_Cloth_17"

Transmog = Transmog or {}
local T = Transmog
T.ID = ID
T.ICON = ICON

local strfind, strsub, strlower, format = string.find, string.sub, string.lower, string.format
local getn, tinsert = table.getn, table.insert

T.on = false
T.unlocked, T.max, T.active, T.nextCost, T.firstFree = 2, 50, 0, 0, false
T.outfits = {}          -- id -> { id, name, icon, situ, auto }
T.looks = {}            -- outfit id -> { [slot] = { look = , ill = } }
T.col = {}              -- slot -> { { item, display, ok }, ... }
T.known = {}            -- item -> display
T.knownDisplay = {}     -- display -> true
T.knownAsked = false
T.ills = nil            -- { { enchant, visual, name }, ... }
T.sets = nil            -- { { id, name, have, total, items = {} }, ... }
T.csets = nil           -- { { id, name, looks = "slot:look:ill/..." }, ... }
T.lookState = {}        -- item -> { state, usable } (tooltips)
T.listeners = {}

-- The transmog slots as the realm numbers them (0-based equipment slots), with the client's
-- slot names, in the order the window shows them.
T.SLOTS = {
    { slot = 0,  name = "HeadSlot",          label = "Head",      hide = true },
    { slot = 2,  name = "ShoulderSlot",      label = "Shoulder",  hide = true },
    { slot = 14, name = "BackSlot",          label = "Back",      hide = true },
    { slot = 4,  name = "ChestSlot",         label = "Chest",     hide = true },
    { slot = 3,  name = "ShirtSlot",         label = "Shirt",     hide = true },
    { slot = 18, name = "TabardSlot",        label = "Tabard",    hide = true },
    { slot = 8,  name = "WristSlot",         label = "Wrist",     hide = true },
    { slot = 9,  name = "HandsSlot",         label = "Hands",     hide = true },
    { slot = 5,  name = "WaistSlot",         label = "Waist",     hide = true },
    { slot = 6,  name = "LegsSlot",          label = "Legs",      hide = true },
    { slot = 7,  name = "FeetSlot",          label = "Feet",      hide = true },
    { slot = 15, name = "MainHandSlot",      label = "Main Hand", weapon = true },
    { slot = 16, name = "SecondaryHandSlot", label = "Off Hand",  weapon = true },
    { slot = 17, name = "RangedSlot",        label = "Ranged" },
}
T.SLOT_BY = {}
for _, s in ipairs(T.SLOTS) do T.SLOT_BY[s.slot] = s end

T.REASON = {
    off = "Transmog isn't on for this realm.",
    npc = "Talk to a Transmogrifier to save looks. Switching outfits works anywhere.",
    money = "Not enough gold.", slot = "That slot can't be transmogrified.",
    look = "You haven't collected that appearance.", class = "Your class can't use that appearance.",
    armor = "That appearance isn't your class's armor type.", fits = "That appearance doesn't go in that slot.",
    hide = "That slot can't be hidden.", outfit = "Pick an outfit first.", name = "Give it a name.",
    full = "No more room.", command = "Unknown command.", busy = "One moment.",
}
local function reason(code) return T.REASON[code or ""] or ("Refused (" .. tostring(code) .. ").") end
T.Reason = reason

local function say(msg) W.Print("|cffc080ffTransmog:|r " .. msg) end
T.Say = say

function T:Send(args)
    if not T.on and args ~= "hi" then return nil end
    return W:SendCommand("tm", args)
end

function T:Listen(fn) tinsert(T.listeners, fn) end
function T:Changed(what, a, b)
    for _, fn in ipairs(T.listeners) do
        local ok, err = pcall(fn, what, a, b)
        if not ok then W:Error("Transmog", err) end
    end
end

-- "4:2470:0;0:-1:0" (or with another separator) -> { [4] = { look = 2470, ill = 0 }, ... }
-- Copper as the game writes it: only the parts there are ("2g", "41s 20c", "15c"), coloured.
function T.CoinText(copper)
    copper = math.floor(tonumber(copper) or 0)
    local g = math.floor(copper / 10000)
    local s = math.floor(math.mod(copper, 10000) / 100)
    local c = math.mod(copper, 100)
    local out = {}
    if g > 0 then table.insert(out, g .. "|cffffd700g|r") end
    if s > 0 then table.insert(out, s .. "|cffc7c7cfs|r") end
    if c > 0 or table.getn(out) == 0 then table.insert(out, c .. "|cffeda55fc|r") end
    return table.concat(out, " ")
end

function T.ParseLooks(text, sep)
    local out = {}
    if not text or text == "" then return out end
    for _, part in ipairs(W.Split(text, sep or ";")) do
        local _, _, s, l, i = strfind(part, "^(%d+):(%-?%d+):(%d+)$")
        if s then out[tonumber(s)] = { look = tonumber(l), ill = tonumber(i) } end
    end
    return out
end

-- { [slot] = { look, ill } } -> "slot:look:ill,..." (sorted by slot, so equal sets compare equal)
function T.FormatLooks(looks, sep)
    local slots = {}
    for s in pairs(looks or {}) do tinsert(slots, s) end
    table.sort(slots)
    local parts = {}
    for _, s in ipairs(slots) do
        local l = looks[s]
        tinsert(parts, s .. ":" .. (l.look or 0) .. ":" .. (l.ill or 0))
    end
    return table.concat(parts, sep or ",")
end

-- Item info, asking the server for an uncached item through the hidden tooltip.
local scan
function T.ItemInfo(id)
    id = tonumber(id)
    if not id or id <= 0 then return nil end
    local name, _, quality, _, _, subType, _, equipLoc, tex = GetItemInfo(id)
    if not name then
        if not scan then
            scan = CreateFrame("GameTooltip", "TransmogScanTip", UIParent, "GameTooltipTemplate")
            scan:SetOwner(UIParent, "ANCHOR_NONE")
        end
        pcall(scan.SetHyperlink, scan, "item:" .. id .. ":0:0:0")
        return nil
    end
    return name, quality, tex, subType, equipLoc
end

function T.ItemLink(id)
    local name, quality = T.ItemInfo(id)
    if not name then return "item " .. tostring(id) end
    local r, g, b = 1, 1, 1
    if GetItemQualityColor then r, g, b = GetItemQualityColor(quality or 1) end
    return format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, name)
end

-- -- the realm's lines ---------------------------------------------------------------------

local function splitHead(body)
    local _, _, head, rest = strfind(body or "", "^([^;]*);?(.*)$")
    return W.Split(head or "", ","), rest or ""
end

local function records(rest)
    if rest == "" then return {} end
    return W.Split(rest, ";")
end

W:RegisterModule("TM", function(body)
    local head, rest = splitHead(body)
    local what = head[1]
    if what == "off" then
        T.on = false
        T:Changed("off")
    elseif what == "on" then
        local first = not T.on
        T.on = true
        T.unlocked = tonumber(head[2]) or 2
        T.max = tonumber(head[3]) or 50
        T.active = tonumber(head[4]) or 0
        T.nextCost = tonumber(head[5]) or 0
        T.firstFree = head[6] == "1"
        if first and W.MicroMenuAdd then W:MicroMenuAdd("Appearances", ICON, "TRANSMOG") end
        T:Changed("hello")
    elseif what == "outfits" then
        T.outfits = {}
        T.order = {}
        for _, rec in ipairs(records(rest)) do
            local f = W.Split(rec, ",")
            local id = tonumber(f[1])
            if id then
                T.outfits[id] = { id = id, name = f[2] or ("Outfit " .. id), icon = tonumber(f[3]) or 0,
                                  situ = tonumber(f[4]) or 0, auto = f[5] == "1" }
                tinsert(T.order, id)
            end
        end
        T:Changed("outfits")
    elseif what == "outfit" then
        local id = tonumber(head[2])
        if id then
            T.looks[id] = T.ParseLooks(rest, ";")
            T:Changed("outfit", id)
        end
    elseif what == "col" then
        local slot = tonumber(head[2])
        local list = {}
        for _, rec in ipairs(records(rest)) do
            local f = W.Split(rec, ",")
            local item, display = tonumber(f[1]), tonumber(f[2])
            if item then
                tinsert(list, { item = item, display = display or 0, ok = f[3] == "1" })
                T.known[item] = display or 0
                if display then T.knownDisplay[display] = true end
            end
        end
        if slot then T.col[slot] = list end
        T:Changed("col", slot)
    elseif what == "known" then
        for _, rec in ipairs(records(rest)) do
            local f = W.Split(rec, ",")
            local item, display = tonumber(f[1]), tonumber(f[2])
            if item then
                T.known[item] = display or 0
                if display then T.knownDisplay[display] = true end
            end
        end
        T:Changed("known")
    elseif what == "look" then
        local item = tonumber(head[2])
        if item then T.lookState[item] = { state = tonumber(head[3]) or -1, usable = head[4] == "1" } end
        T:Changed("look", item)
    elseif what == "ill" then
        T.ills = {}
        for _, rec in ipairs(records(rest)) do
            local f = W.Split(rec, ",")
            if tonumber(f[1]) then tinsert(T.ills, { enchant = tonumber(f[1]), visual = tonumber(f[2]) or 0, name = f[3] or "" }) end
        end
        T:Changed("ill")
    elseif what == "sets" then
        T.sets = {}
        for _, rec in ipairs(records(rest)) do
            local f = W.Split(rec, ",")
            if tonumber(f[1]) then
                local items = {}
                for _, it in ipairs(W.Split(f[5] or "", "/")) do if tonumber(it) then tinsert(items, tonumber(it)) end end
                tinsert(T.sets, { id = tonumber(f[1]), name = (f[2] and f[2] ~= "") and f[2] or ("Set " .. f[1]),
                                  have = tonumber(f[3]) or 0, total = tonumber(f[4]) or 0, items = items })
            end
        end
        table.sort(T.sets, function(a, b)
            if a.have ~= b.have then return a.have > b.have end
            return a.name < b.name
        end)
        T:Changed("sets")
    elseif what == "csets" then
        T.csets = {}
        for _, rec in ipairs(records(rest)) do
            local f = W.Split(rec, ",")
            if tonumber(f[1]) then tinsert(T.csets, { id = tonumber(f[1]), name = f[2] or "", looks = f[3] or "" }) end
        end
        T:Changed("csets")
    elseif what == "cost" then
        T:Changed("cost", tonumber(head[2]), tonumber(head[3]) or 0)
    elseif what == "saved" then
        local id, paid = tonumber(head[2]), tonumber(head[3]) or 0
        if paid > 0 then say("Outfit saved for " .. UI.CoinText(paid) .. ".") else say("Outfit saved.") end
        T.firstFree = false
        T:Send("outfit " .. (id or 0))
        T:Send("hi")
        T:Changed("saved", id, paid)
    elseif what == "active" then
        T.active = tonumber(head[2]) or 0
        if head[3] == "1" and T.outfits[T.active] then
            say("Situation: now wearing " .. T.outfits[T.active].name .. ".")
        end
        T:Changed("active", T.active)
    elseif what == "unlocked" then
        T.unlocked = tonumber(head[2]) or T.unlocked
        T.nextCost = tonumber(head[3]) or 0
        say("Outfit slot " .. T.unlocked .. " unlocked.")
        T:Changed("unlocked")
    elseif what == "named" or what == "iconed" then
        T:Changed(what, tonumber(head[2]))
    elseif what == "situ" then
        local id = tonumber(head[2])
        if id and T.outfits[id] then T.outfits[id].situ = tonumber(head[3]) or 0 end
        T:Changed("situ", id)
    elseif what == "cset" then
        T:Send("cset list")
    elseif what == "new" then
        local item, display = tonumber(head[2]), tonumber(head[3])
        if item then
            local fresh = display and not T.knownDisplay[display]
            T.known[item] = display or 0
            if display then T.knownDisplay[display] = true end
            T.lookState[item] = nil
            for s in pairs(T.col) do T.col[s] = nil end
            if fresh then
                W.Print("|cffc080ffAppearance added to your collection:|r " .. T.ItemLink(item))
            end
            T:Changed("new", item)
        end
    elseif what == "newill" then
        T.ills = nil
        say("Illusion added to your collection.")
        T:Changed("new")
    elseif what == "err" then
        say("|cffff4040" .. reason(head[2]) .. "|r")
        T:Changed("err", head[2])
    end
end)

-- -- tooltips: whether the hovered item's look is collected ---------------------------------

local EQUIP_LOOK = {
    INVTYPE_HEAD = 1, INVTYPE_SHOULDER = 1, INVTYPE_CLOAK = 1, INVTYPE_CHEST = 1, INVTYPE_ROBE = 1,
    INVTYPE_BODY = 1, INVTYPE_TABARD = 1, INVTYPE_WRIST = 1, INVTYPE_HAND = 1, INVTYPE_WAIST = 1,
    INVTYPE_LEGS = 1, INVTYPE_FEET = 1, INVTYPE_WEAPON = 1, INVTYPE_2HWEAPON = 1, INVTYPE_WEAPONMAINHAND = 1,
    INVTYPE_WEAPONOFFHAND = 1, INVTYPE_SHIELD = 1, INVTYPE_HOLDABLE = 1, INVTYPE_RANGED = 1,
    INVTYPE_RANGEDRIGHT = 1, INVTYPE_THROWN = 1,
}
T.EQUIP_LOOK = EQUIP_LOOK

local asked = {}
local function lookLine(tooltip, link)
    if not T.on or not link then return end
    local _, _, id = strfind(link, "item:(%d+)")
    id = tonumber(id)
    if not id then return end
    local _, _, _, _, equipLoc = T.ItemInfo(id)
    if not equipLoc or not EQUIP_LOOK[equipLoc] then return end
    local text
    if T.known[id] then
        return                                  -- collected from this item: retail adds nothing
    end
    local st = T.lookState[id]
    if not st then
        if not asked[id] then
            asked[id] = true
            T:Send("look " .. id)
        end
        return
    end
    if st.state == 0 then text = "You haven't collected this appearance"
    elseif st.state == 1 then text = "You've collected this appearance, but not from this item"
    else return end
    tooltip:AddLine(text, 0.53, 0.53, 0.93)
    tooltip:Show()
end
T.LookLine = lookLine

local function hook(method, linkOf)
    local original = GameTooltip[method]
    if not original then return end
    GameTooltip[method] = function(self, a1, a2, a3)
        local r1, r2, r3 = original(self, a1, a2, a3)
        local ok, link = pcall(linkOf, a1, a2, a3)
        if ok then pcall(lookLine, self, link) end
        return r1, r2, r3
    end
end
hook("SetBagItem", function(bag, slot) return GetContainerItemLink(bag, slot) end)
hook("SetHyperlink", function(link) return link end)
hook("SetLootItem", function(slot) return GetLootSlotLink(slot) end)
hook("SetMerchantItem", function(i) return GetMerchantItemLink(i) end)
hook("SetAuctionItem", function(kind, i) return GetAuctionItemLink(kind, i) end)
hook("SetQuestItem", function(kind, i) return GetQuestItemLink(kind, i) end)
hook("SetQuestLogItem", function(kind, i) return GetQuestLogItemLink(kind, i) end)
hook("SetTradeTargetItem", function(i) return GetTradeTargetItemLink(i) end)

-- -- custom set chat links -------------------------------------------------------------------
-- Sent as plain text "[Look: Name]{ov:4:2470:0/0:-1:0}" so players without the addon see the
-- name; with it the chat frame shows a clickable [Look: Name] that opens the dressing room.

function T.LinkText(name, looks)
    return "[Look: " .. (name or "Look") .. "]{ov:" .. (looks or "") .. "}"
end

local function rewrite(msg)
    if type(msg) ~= "string" or not strfind(msg, "{ov:", 1, true) then return msg end
    local out = string.gsub(msg, "%[Look: ([^%]]*)%]{ov:([%d:/%-]*)}", function(name, looks)
        return "|cffc080ff|Hovlook:" .. looks .. "|h[Look: " .. name .. "]|h|r"
    end)
    return out
end
T.RewriteLink = rewrite

if ChatFrame_OnEvent then
    local orig = ChatFrame_OnEvent
    ChatFrame_OnEvent = function(ev)
        if arg1 and type(arg1) == "string" and strfind(arg1, "{ov:", 1, true) then arg1 = rewrite(arg1) end
        return orig(ev)
    end
end

if SetItemRef then
    local origRef = SetItemRef
    SetItemRef = function(link, text, button)
        if type(link) == "string" and strsub(link, 1, 7) == "ovlook:" then
            if T.PreviewLooks then T:PreviewLooks(T.ParseLooks(strsub(link, 8), "/"), "Linked look") end
            return
        end
        return origRef(link, text, button)
    end
end

-- -- /outfit --------------------------------------------------------------------------------

function T:UseOutfit(id)
    if not T.on then say("Transmog isn't on for this realm.") return end
    id = tonumber(id)
    if not id or id < 0 or id > T.unlocked then say("/outfit 0-" .. T.unlocked .. " (0 shows your equipped gear).") return end
    T:Send("use " .. id)
end

SLASH_TRANSMOGOUTFIT1 = "/outfit"
SlashCmdList["TRANSMOGOUTFIT"] = function(msg)
    msg = W.Trim(msg or "")
    if msg == "" then
        if T.Toggle then T:Toggle("outfits") end
        return
    end
    -- by number or by name
    local n = tonumber(msg)
    if not n then
        for id, o in pairs(T.outfits) do if strlower(o.name) == strlower(msg) then n = id end end
    end
    T:UseOutfit(n)
end

SLASH_TRANSMOG1 = "/transmog"
SLASH_TRANSMOG2 = "/tmog"
SLASH_TRANSMOG3 = "/appearances"
SlashCmdList["TRANSMOG"] = function(msg)
    if T.Toggle then T:Toggle() end
end

-- -- hello -----------------------------------------------------------------------------------

local poll = CreateFrame("Frame", "Transmog_Poll")
poll:SetScript("OnUpdate", function()
    if T.asked or not W.connected or not W:IsActive(ID) then return end
    T.asked = true
    W:SendCommand("tm", "hi")
    poll:Hide()
end)

W:RegisterSchema(ID, {
    title = "Transmog",
    icon = ICON,
    desc = "Appearances and outfits: collect looks, save them to outfits at a Transmogrifier, switch for free anywhere with /outfit.",
    defaults = { icons = false },
    options = {},
})
W:RegisterAddon(ID, function(on)
    if not on and T.win then T.win:Hide() end
end)
