--[[
    LogDetail.lua  -  Quests: the quest log's right pane and its buttons.

    For a quest: title (difficulty colour), level, zone and tags, "Part 2 of 4" when the realm
    knows the chain, objectives with live progress bars, the description, rewards (hover for
    the item, a green arrow when it beats what you wear, Shift-click to link it), money and
    experience, who to turn it in to and where, who gave it, and your party's progress.
    Buttons: Track / Untrack, Show on map, Share, Abandon (with a confirmation and 10 seconds
    to undo). The Nearby and Completed pages reuse the pane for their own entries.
]]--

local W = WenillaCore
local UI = W.UI
local Q = Compass
local Log = Q.Log
local win = Log.win

local floor = math.floor
local PANE_W = 412
local BODY_W = 384

local detail = CreateFrame("Frame", "Compass_LogDetail", win)
UI.Skin(detail, "inset")
detail:SetPoint("TOPLEFT", Log.listBg, "TOPRIGHT", 6, 0)
detail:SetWidth(PANE_W)
detail:SetHeight(Log.listBg:GetHeight())
Log.detail = detail

local scroll = CreateFrame("ScrollFrame", "Compass_LogDetailScroll", detail)
scroll:SetPoint("TOPLEFT", detail, "TOPLEFT", 8, -8)
scroll:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -8, 8)
scroll:EnableMouseWheel(true)
local body = CreateFrame("Frame", "Compass_LogDetailBody", scroll)
body:SetWidth(BODY_W + 8)
body:SetHeight(400)
scroll:SetScrollChild(body)
Log.body = body
scroll:SetScript("OnMouseWheel", function()
    local max = math.max(0, (body:GetHeight() or 0) - (scroll:GetHeight() or 0))
    local v = (scroll:GetVerticalScroll() or 0) - (arg1 or 0) * 30
    if v < 0 then v = 0 elseif v > max then v = max end
    scroll:SetVerticalScroll(v)
end)

-- -- Pools of pieces, laid out top to bottom ------------------------------------------------------

local pools, used = {}, {}
local y = 0

local function take(kind, make)
    pools[kind] = pools[kind] or {}
    used[kind] = (used[kind] or 0) + 1
    local p = pools[kind][used[kind]]
    if not p then
        p = make(used[kind])
        pools[kind][used[kind]] = p
    end
    p:Show()
    return p
end

local function reset()
    for _, list in pairs(pools) do
        for _, p in ipairs(list) do p:Hide() end
    end
    used = {}
    y = -2
    scroll:SetVerticalScroll(0)
end

local function text(str, size, color, indent, gap)
    local fs = take("text" .. size, function() return UI.Label(body, size, nil, size >= 13 and "OUTLINE" or nil) end)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", body, "TOPLEFT", indent or 2, y)
    fs:SetWidth(BODY_W - (indent or 2))
    fs:SetText(str)
    local c = color or { 0.92, 0.92, 0.94 }
    fs:SetTextColor(c[1], c[2], c[3])
    local h = fs:GetHeight() or 12
    if h < size then h = size + 2 end
    y = y - h - (gap or 4)
    return fs
end

local function header(str)
    y = y - 6
    local f = take("header", function()
        local h = CreateFrame("Frame", nil, body)
        h:SetWidth(BODY_W)
        h:SetHeight(14)
        h.label = UI.Label(h, 10, UI.MUTED, "OUTLINE")
        h.label:SetPoint("LEFT", h, "LEFT", 0, 0)
        h.line = UI.Divider(h)
        h.line:SetPoint("LEFT", h.label, "RIGHT", 6, 0)
        h.line:SetPoint("RIGHT", h, "RIGHT", 0, 0)
        return h
    end)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", body, "TOPLEFT", 2, y)
    f.label:SetText(string.upper(str))
    y = y - 18
    return f
end

local function bar(o)
    local b = take("bar", function(i)
        local r = UI.Bar(body, { width = BODY_W - 6, height = 16 })
        r:EnableMouse(false)
        return r
    end)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", body, "TOPLEFT", 4, y)
    b.left:SetText(o.name)
    if o.need > 1 or o.type == "item" or o.type == "monster" then
        b.right:SetText(o.have .. "/" .. o.need)
    else
        b.right:SetText(o.done and "Done" or "")
    end
    b:SetFraction(o.need > 0 and (o.have / o.need) or 0)
    if o.done then b:SetColor(0.24, 0.62, 0.24) else b:SetColor(0.72, 0.55, 0.12) end
    y = y - 19
    return b
end

-- -- Item comparison (simple: stats, armour and damage read from the tooltip) -----------------------

local scan = CreateFrame("GameTooltip", "Compass_ScanTip", nil, "GameTooltipTemplate")
scan:SetOwner(UIParent, "ANCHOR_NONE")

local SLOT_TEXT = {
    Head = { 1 }, Neck = { 2 }, Shoulder = { 3 }, Shirt = { 4 }, Chest = { 5 }, Waist = { 6 }, Legs = { 7 },
    Feet = { 8 }, Wrist = { 9 }, Hands = { 10 }, Finger = { 11, 12 }, Trinket = { 13, 14 }, Back = { 15 },
    ["Main Hand"] = { 16 }, ["One-Hand"] = { 16, 17 }, ["Two-Hand"] = { 16 }, ["Off Hand"] = { 17 },
    ["Held In Off-hand"] = { 17 }, Ranged = { 18 }, Thrown = { 18 }, Relic = { 18 }, Tabard = { 19 },
}

-- score, slots, name of an item link
function Q:ItemScore(link)
    if not link then return nil end
    scan:SetOwner(UIParent, "ANCHOR_NONE")
    scan:ClearLines()
    scan:SetHyperlink(link)
    local score, slots, stats = 0, nil, false
    local name
    for i = 1, (scan:NumLines() or 0) do
        local l = getglobal("Compass_ScanTipTextLeft" .. i)
        local t = l and l:GetText()
        if t then
            if i == 1 then name = t end
            if SLOT_TEXT[t] then slots = SLOT_TEXT[t] end
            local _, _, armor = string.find(t, "^(%d+) Armor")
            if armor then score = score + tonumber(armor) / 10; stats = true end
            local _, _, dps = string.find(t, "%(([%d%.]+) damage per second%)")
            if dps then score = score + tonumber(dps) * 2; stats = true end
            for v in string.gfind(t, "%+(%d+) %a") do score = score + tonumber(v); stats = true end
        end
    end
    local _, _, quality = GetItemInfo(tonumber((string.gsub(link, "^.-item:(%d+).*$", "%1"))) or 0)
    if not stats then score = (quality or 1) * 3 end
    return score, slots, name
end

-- Is the item an upgrade over what you wear in its slot? Returns delta, equipped item name.
function Q:Upgrade(link)
    local score, slots = self:ItemScore(link)
    if not score or not slots then return nil end
    local worst, worstName
    for _, slot in ipairs(slots) do
        local eq = GetInventoryItemLink("player", slot)
        local s, _, n = 0, nil, nil
        if eq then s, _, n = self:ItemScore(eq) end
        s = s or 0
        if not worst or s < worst then worst, worstName = s, n end
    end
    return score - (worst or 0), worstName
end

-- The best choice reward (by upgrade, then quality) among a quest's choices.
-- reader(i) -> name, texture, count, quality, usable, link
function Q:BestChoice(n, reader)
    local best, bestScore
    for i = 1, n do
        local _, _, _, quality, usable, link = reader(i)
        local s = (quality or 1) * 0.01
        if usable and usable ~= 0 then
            local d = link and self:Upgrade(link)
            if d then s = s + d end
        else
            s = s - 1000            -- 1.12 answers nil for items you cannot use
        end
        if not bestScore or s > bestScore then best, bestScore = i, s end
    end
    return best or 1
end

-- -- Rewards ----------------------------------------------------------------------------------------

local function rewardButton(i)
    local b = CreateFrame("Button", "Compass_LogReward" .. i, body)
    b:SetWidth(186)
    b:SetHeight(34)
    b.box = UI.IconBox(b, 32)
    b.box:SetPoint("LEFT", b, "LEFT", 0, 0)
    b.count = UI.Label(b.box, 10, { 1, 1, 1 }, "OUTLINE")
    b.count:SetPoint("BOTTOMRIGHT", b.box, "BOTTOMRIGHT", -2, 2)
    b.count:SetJustifyH("RIGHT")
    b.up = b.box:CreateTexture(nil, "OVERLAY")
    b.up:SetWidth(14)
    b.up:SetHeight(14)
    b.up:SetPoint("TOPLEFT", b.box, "TOPLEFT", -3, 3)
    b.name = UI.Label(b, 10, nil, nil)
    b.name:SetPoint("LEFT", b.box, "RIGHT", 6, 0)
    b.name:SetWidth(146)
    b.best = b:CreateTexture(nil, "BACKGROUND")
    b.best:SetAllPoints(b)
    b.best:SetTexture(0.3, 0.9, 0.4, 0.12)
    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        if this.link then GameTooltip:SetHyperlink(this.link) else GameTooltip:SetText(this.itemName or "", 1, 1, 1) end
        if this.upText then GameTooltip:AddLine(this.upText, 0.3, 1, 0.4) end
        if this.isBest then GameTooltip:AddLine("Auto-pick would choose this one.", 0.6, 0.9, 0.6) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function()
        if IsShiftKeyDown() and this.link then Q:InsertChat(this.link) end
    end)
    return b
end

local function rewards(info)
    local col = 0
    local function place(r, isBest)
        local b = take("reward", rewardButton)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", body, "TOPLEFT", 4 + col * 192, y)
        b.box.icon:SetTexture(r.texture or UI.UNKNOWN_ICON)
        b.count:SetText((r.count and r.count > 1) and r.count or "")
        local qc = (r.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[r.quality]) or nil
        b.name:SetText(r.name or "")
        if qc then b.name:SetTextColor(qc.r, qc.g, qc.b) else b.name:SetTextColor(1, 1, 1) end
        b.link, b.itemName, b.isBest = r.link, r.name, isBest
        b.upText = nil
        b.up:Hide()
        if r.link and r.usable and r.usable ~= 0 then
            local d, eqName = Q:Upgrade(r.link)
            if d and d > 0 then
                b.upText = "Upgrade over " .. (eqName or "an empty slot")
                if not W:Art(b.up, "Quests_Upgrade", nil) then
                    b.up:SetTexture("Interface\\Buttons\\UI-MicroStream-Green")
                end
                b.up:Show()
            end
        end
        if isBest then b.best:Show() else b.best:Hide() end
        col = col + 1
        if col > 1 then
            col = 0
            y = y - 38
        end
    end
    if info.choices[1] then
        text("Choose one of:", 10, UI.MUTED, 2, 2)
        for i, r in ipairs(info.choices) do place(r, Q:Get("autoPick") and i == info.best) end
        if col == 1 then col = 0; y = y - 38 end
    end
    if info.rewards[1] then
        text(info.choices[1] and "You will also receive:" or "You will receive:", 10, UI.MUTED, 2, 2)
        for _, r in ipairs(info.rewards) do place(r, false) end
        if col == 1 then col = 0; y = y - 38 end
    end
    local extra = {}
    if info.money and info.money > 0 then table.insert(extra, UI.CoinText(info.money)) end
    if info.xp and info.xp > 0 then table.insert(extra, info.xp .. " experience") end
    if extra[1] then text(table.concat(extra, "   "), 11, { 1, 1, 1 }, 2) end
end

-- Everything the stock API knows about one quest (selects it, then restores the selection).
function Q:QuestInfo(q)
    local info = Q:WithSelected(q.title, function()
        local r = { rewards = {}, choices = {} }
        if GetQuestLogQuestText then r.desc, r.objText = GetQuestLogQuestText() end
        r.money = GetQuestLogRewardMoney and GetQuestLogRewardMoney() or 0
        for i = 1, (GetNumQuestLogRewards and GetNumQuestLogRewards() or 0) do
            local name, texture, count, quality, usable = GetQuestLogRewardInfo(i)
            table.insert(r.rewards, { name = name, texture = texture, count = count, quality = quality, usable = usable,
                link = GetQuestLogItemLink and GetQuestLogItemLink("reward", i) })
        end
        for i = 1, (GetNumQuestLogChoices and GetNumQuestLogChoices() or 0) do
            local name, texture, count, quality, usable = GetQuestLogChoiceInfo(i)
            table.insert(r.choices, { name = name, texture = texture, count = count, quality = quality, usable = usable,
                link = GetQuestLogItemLink and GetQuestLogItemLink("choice", i) })
        end
        r.pushable = GetQuestLogPushable and GetQuestLogPushable() and true or false
        return r
    end)
    info = info or { rewards = {}, choices = {} }
    if info.choices[1] then
        info.best = Q:BestChoice(table.getn(info.choices), function(i)
            local c = info.choices[i]
            return c.name, c.texture, c.count, c.quality, c.usable, c.link
        end)
    end
    local m = self.meta[q.title]
    if m then info.xp = m.xp end
    return info
end

-- -- Buttons -----------------------------------------------------------------------------------------

local bar_ = CreateFrame("Frame", "Compass_LogButtons", win)
bar_:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 8, 10)
bar_:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -8, 10)
bar_:SetHeight(22)
Log.buttons = bar_

local buttons = {}
for i = 1, 4 do
    local b = Log.Flat(bar_, "Compass_LogBtn" .. i, "", 98)
    b:SetPoint("RIGHT", bar_, "RIGHT", -(4 - i) * 102, 0)
    buttons[i] = b
end
Log.btn = buttons

local status = UI.Label(bar_, 10, UI.MUTED)
status:SetPoint("LEFT", bar_, "LEFT", 4, 0)
status:SetWidth(276)
if status.SetNonSpaceWrap then status:SetNonSpaceWrap(false) end
Log.status = status

-- Undo strip: "Abandoning "X" in 7 s   [Undo]"
local undo = CreateFrame("Frame", "Compass_LogUndo", bar_)
undo:SetPoint("LEFT", bar_, "LEFT", 0, 0)
undo:SetWidth(278)
undo:SetHeight(22)
UI.Skin(undo, "raised")
undo:SetBackdropBorderColor(0.85, 0.35, 0.28, 1)
undo.text = UI.Label(undo, 10, { 1, 0.75, 0.7 })
undo.text:SetPoint("LEFT", undo, "LEFT", 8, 0)
undo.text:SetWidth(210)
local undoBtn = Log.Flat(undo, "Compass_LogUndoButton", "Undo", 56, function() Q:UndoAbandon() end)
undoBtn:SetPoint("RIGHT", undo, "RIGHT", -2, 0)
undo:Hide()
Log.undo = undo

local function setButtons(defs)
    for i = 1, 4 do
        local d = defs[i]
        local b = buttons[i]
        if d then
            b:SetText(d[1])
            b:SetScript("OnClick", d[2])
            b:SetDisabled(d[3])
            b:Show()
        else
            b:Hide()
        end
    end
end

-- -- Abandon (confirm, then 10 seconds to undo) --------------------------------------------------------

StaticPopupDialogs["COMPASS_ABANDON"] = {
    text = "Abandon \"%s\"?\nYou can undo it for 10 seconds.",
    button1 = "Abandon", button2 = "Cancel",
    OnAccept = function() if Q.abandonAsk then Q:QueueAbandon(Q.abandonAsk) end end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}
StaticPopupDialogs["COMPASS_ABANDON_GREYS"] = {
    text = "Abandon %s grey quests?\nThey give little or no experience now. You can undo it for 10 seconds.",
    button1 = "Abandon", button2 = "Cancel",
    OnAccept = function() if Q.abandonAsk then Q:QueueAbandon(Q.abandonAsk) end end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

function Log:IsAbandoning(title)
    local p = Q.pendingAbandon
    if not p then return false end
    for _, t in ipairs(p.titles) do if t == title then return true end end
    return false
end

function Log:AskAbandon(title)
    Q.abandonAsk = { title }
    StaticPopup_Show("COMPASS_ABANDON", title)
end

function Log:GreyQuests()
    local out = {}
    for _, q in ipairs(Q.quests) do
        if Q:IsGrey(q.level) and not q.complete then table.insert(out, q.title) end
    end
    return out
end

function Log:AskAbandonGreys()
    local greys = self:GreyQuests()
    if not greys[1] then return end
    Q.abandonAsk = greys
    StaticPopup_Show("COMPASS_ABANDON_GREYS", tostring(table.getn(greys)))
end

function Q:QueueAbandon(titles)
    if self.pendingAbandon then self:FinishAbandon() end
    self.pendingAbandon = { titles = titles, at = GetTime() + 10 }
    self.abandonAsk = nil
    local n = table.getn(titles)
    local what = (n == 1) and ("\"" .. titles[1] .. "\"") or (n .. " quests")
    self.abandonToast = UI.Toast({ icon = "Interface\\Icons\\Ability_Rogue_FeignDeath", title = "Abandoning " .. what,
        text = "Click here within 10 seconds to keep " .. ((n == 1) and "it" or "them") .. ".",
        color = { 1, 0.45, 0.35 }, duration = 10, onClick = function() Q:UndoAbandon() end })
    if PlaySound then PlaySound("igQuestLogAbandonQuest") end
    self:Fire("AbandonChanged")
end

function Q:UndoAbandon()
    local p = self.pendingAbandon
    if not p then return end
    self.pendingAbandon = nil
    if self.abandonToast and self.abandonToast:IsShown() then
        self.abandonToast.onClick = nil
        self.abandonToast:Hide()
    end
    local n = table.getn(p.titles)
    self:Print((n == 1) and ("Kept \"" .. p.titles[1] .. "\".") or ("Kept " .. n .. " quests."))
    self:Fire("AbandonChanged")
end

function Q:FinishAbandon()
    local p = self.pendingAbandon
    if not p then return end
    self.pendingAbandon = nil
    for _, title in ipairs(p.titles) do
        local idx = self:IndexOf(title)
        if idx then
            SelectQuestLogEntry(idx)
            if SetAbandonQuest then SetAbandonQuest() end
            AbandonQuest()
        end
    end
    self:RequestScan()
    self:Fire("AbandonChanged")
end

Q:Every(0.2, function()
    local p = Q.pendingAbandon
    if not p then
        undo:Hide()
        return
    end
    local left = p.at - GetTime()
    if left <= 0 then
        Q:FinishAbandon()
        undo:Hide()
        return
    end
    local n = table.getn(p.titles)
    undo.text:SetText("Abandoning " .. ((n == 1) and ("\"" .. p.titles[1] .. "\"") or (n .. " quests")) .. " in " .. math.ceil(left) .. " s")
    undo:Show()
end)

-- -- Rendering ----------------------------------------------------------------------------------------

local function locationText(zone, x, y_)
    if not x then return zone or "" end
    return (zone and (zone .. " ") or "") .. "(" .. floor(x * 100 + 0.5) .. ", " .. floor(y_ * 100 + 0.5) .. ")"
end

local function questPage(q)
    local r, g, b = Q:DiffColor(q.level)
    text(q.title, 14, { r, g, b }, 2, 2)
    local meta = { "Level " .. q.level, q.zone }
    for _, t in ipairs(Q:Tags(q)) do table.insert(meta, t) end
    local m = Q.meta[q.title]
    if m and m.chainPos and m.chainLen and m.chainLen > 1 then
        table.insert(meta, "Part " .. m.chainPos .. " of " .. m.chainLen)
    end
    text(table.concat(meta, " · "), 10, UI.MUTED, 2, 6)
    if Log:IsAbandoning(q.title) then
        text("Being abandoned - use Undo below to keep it.", 11, { 1, 0.45, 0.35 })
    elseif q.failed then
        text("Failed. Abandon it and pick it up again to retry.", 11, { 1, 0.3, 0.25 })
    elseif q.complete then
        text("Complete - ready to turn in.", 11, { 1, 0.82, 0 })
    end

    local info = Q:QuestInfo(q)
    header("Objectives")
    if q.objectives[1] then
        for _, o in ipairs(q.objectives) do bar(o) end
    end
    if info.objText and info.objText ~= "" then text(info.objText, 11, { 0.86, 0.84, 0.78 }, 2, 2) end
    if not q.objectives[1] and not (info.objText and info.objText ~= "") then text("No objectives listed.", 10, UI.MUTED) end

    if info.desc and info.desc ~= "" then
        header("Description")
        text(info.desc, 11, { 0.86, 0.84, 0.78 })
    end

    if info.rewards[1] or info.choices[1] or (info.money or 0) > 0 or (info.xp or 0) > 0 then
        header("Rewards")
        rewards(info)
    end

    local turnIn = m and m.turnIn
    local giver = Q:DB().givers[q.title]
    if turnIn or giver then
        header("Who and where")
        if turnIn then
            text("Turn in: " .. (turnIn.npc or "unknown") .. (turnIn.x and (", " .. locationText(turnIn.zone, turnIn.x, turnIn.y)) or ""), 11, { 1, 1, 1 })
        end
        if giver then
            text("Picked up from " .. (giver.npc or "a quest giver") .. ", " .. locationText(giver.zone, giver.x, giver.y), 11, { 0.85, 0.85, 0.88 })
        end
    end
    local _, dist = Q:BestNode(q.key)
    if dist then text((q.complete and "Turn-in " or "Nearest objective ") .. Q:YardText(dist) .. " away.", 10, UI.MUTED) end

    local party = Q:PartyProgress(q.title)
    if party[1] then
        header("Your party")
        for _, p in ipairs(party) do
            text(p.name .. ": " .. (p.complete and "done" or p.text), 11, p.complete and { 0.45, 1, 0.45 } or { 1, 1, 1 })
        end
    end

    local replies = Q.shareReplies[q.title]
    if replies and replies[1] then
        status:SetText("Shared: " .. table.concat(replies, " · "))
    else
        status:SetText("")
    end

    local tracked = Q:IsTracked(q.key)
    setButtons({
        { tracked and "Untrack" or "Track", function() Q:SetTracked(q.key, not tracked); Log:Refresh() end },
        { "Show on map", function()
            if Q:ShowOnMap(q.key) == 0 then Q:Print("No map pins for \"" .. q.title .. "\" yet.") end
        end },
        { "Share", function() Q:Share(q.title) end, not info.pushable or not ((GetNumPartyMembers() or 0) > 0) },
        { "Abandon", function() Log:AskAbandon(q.title) end, Log:IsAbandoning(q.title) },
    })
end

local function nearbyPage(e)
    local r, g, b = Q:DiffColor(e.level)
    text(e.title, 14, { r, g, b }, 2, 2)
    text("Level " .. e.level .. (e.minLevel > 0 and (" · from level " .. e.minLevel) or "") .. " · " .. (e.zone or ""), 10, UI.MUTED, 2, 6)
    header("Where")
    text((e.giver and (e.giver .. ", ") or "") .. locationText(e.zone, e.x, e.y), 11, { 1, 1, 1 })
    if e.dist then text(Q:YardText(e.dist) .. " away.", 10, UI.MUTED) end
    if UnitLevel("player") < (e.minLevel or 0) then
        text("You can take it from level " .. e.minLevel .. ".", 11, { 1, 0.45, 0.35 })
    end
    status:SetText("")
    setButtons({
        { "Point the arrow", function()
            Q:SetWaypoint({ x = e.x, y = e.y, zone = e.zone, title = e.title, kind = "GIVER", label = e.giver })
        end },
    })
end

local function historyPage(h)
    text(h.title, 14, { 0.92, 0.92, 0.94 }, 2, 2)
    local when = date("%d %b %Y, %H:%M", h.t or 0)
    text("Level " .. (h.level or 0) .. " · " .. (h.zone or "") .. " · " .. when, 10, UI.MUTED, 2, 6)
    if h.how == "abandoned" then
        text("Abandoned.", 11, { 1, 0.55, 0.45 })
        header("Taking it again")
        if h.giver then
            text("Talk to " .. (h.giver.npc or "the quest giver") .. " again, " .. locationText(h.giver.zone, h.giver.x, h.giver.y) .. ".", 11, { 1, 1, 1 })
        else
            text("The game cannot put an abandoned quest back. Go back to whoever gave it to you to pick it up again.", 11, { 1, 1, 1 })
        end
        -- Q.realmPlus: the realm answered np/qz/qm, so it has the update that serves "qundo"
        if W.connected and Q.realmPlus then text("Or ask the realm to restore it, progress and all.", 10, UI.MUTED) end
    else
        text("Turned in.", 11, { 0.45, 1, 0.45 })
    end
    status:SetText("")
    local defs = {}
    if h.how == "abandoned" and h.giver and h.giver.x and h.giver.zone == Q:Zone() then
        table.insert(defs, { "Point the arrow", function()
            Q:SetWaypoint({ x = h.giver.x, y = h.giver.y, zone = h.giver.zone, title = h.giver.npc or h.title, kind = "GIVER", label = h.title })
        end })
    end
    if h.how == "abandoned" and W.connected and Q.realmPlus then
        table.insert(defs, { "Restore", function()
            W:SendCommand("qundo", h.title)
            Q:Print("Asking the realm to restore \"" .. h.title .. "\"...")
        end })
    end
    setButtons(defs)
end

function Log:UpdateDetail()
    if not win:IsShown() or self.page == "options" then return end
    reset()
    local sel = self.selected
    if self.page == "quests" then
        local q = sel and Q.byKey[sel]
        if q then
            questPage(q)
        else
            text("Pick a quest on the left.", 11, UI.MUTED)
            status:SetText("")
            setButtons({})
        end
    elseif self.page == "nearby" then
        local found
        for _, e in ipairs(Q.nearby) do if sel == "nearby:" .. e.title then found = e end end
        if found then nearbyPage(found) else setButtons({}) end
    elseif self.page == "history" then
        local _, _, i = string.find(sel or "", "^history:(%d+)$")
        local h = i and Q:DB().history[tonumber(i)]
        if h then historyPage(h) else setButtons({}) end
    end
    body:SetHeight(math.max(40, -y + 8))
end

Q:Listen("PartyChanged", function() Log:UpdateDetail() end)
Q:Listen("ShareChanged", function() Log:UpdateDetail() end)
Q:Listen("MetaChanged", function() Log:UpdateDetail() end)
Q:Listen("AbandonChanged", function() Log:Refresh() end)
