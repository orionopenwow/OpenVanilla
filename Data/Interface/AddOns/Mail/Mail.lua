--[[
    Mail.lua
    The mailbox, made quick (in the spirit of Postal):

      * Open All takes the money and the item from every letter, one request at a time (the
        1.12 server answers one mail request per MAIL_INBOX_UPDATE; faster and it drops them).
        It pauses when your bags are full and carries on when you make room. Cash-on-delivery
        letters are skipped unless you Shift-click and confirm the price.
      * Return All sends every player's letter back; ticked letters can be opened or returned
        on their own (a checkbox on each inbox row).
      * Alt-click an item in your bags to attach it. More than one item goes out as several
        letters, "Subject (1/3)", "(2/3)", ... (1.12 letters carry one item each).
      * Name suggestions while you type the recipient: your other characters on this realm
        (remembered as you log in), people you mailed recently, friends and guild.
      * An attachment list with a search box: every item waiting in the inbox, click to take it.
      * One summary line when a run finishes: "Collected 3g 12s and 7 items".
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Mail"

ClassicPlusMail = ClassicPlusMail or {}
local P = ClassicPlusMail

local floor, strlower, strfind, strsub, strlen = math.floor, string.lower, string.find, string.sub, string.len
local getn = table.getn

local MAX_OUTBOX = 11          -- plus the stock attachment slot: 12 letters at most per send
local STEP_TIMEOUT = 4         -- seconds to wait for the server before asking again
local LETTER_ICON = "Interface\\Icons\\INV_Letter_15"

local QUALITY_HEX = { [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ff1eff00", [3] = "ff0070dd", [4] = "ffa335ee", [5] = "ffff8000" }

-- -- Helpers -------------------------------------------------------------------------------

local function active() return W:IsActive(ID) end
local function opt(key) return active() and W:Setting(ID, key, true) end

local function say(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Mail:|r " .. msg) end
end

-- "3g 12s" (only the parts that are not zero), coloured like the coin letters.
function P.Coins(copper)
    copper = floor(tonumber(copper) or 0)
    local g = floor(copper / 10000)
    local s = floor((copper - g * 10000) / 100)
    local c = copper - g * 10000 - s * 100
    local out = {}
    if g > 0 then table.insert(out, g .. "|cffffd700g|r") end
    if s > 0 then table.insert(out, s .. "|cffc7c7cfs|r") end
    if c > 0 or getn(out) == 0 then table.insert(out, c .. "|cffeda55fc|r") end
    return table.concat(out, " ")
end
local Coins = P.Coins

local function plural(n, one, many) return n .. " " .. ((n == 1) and one or (many or (one .. "s"))) end

local function realm() return GetRealmName and GetRealmName() or "?" end
local function me() return UnitName("player") or "?" end

local function db()
    if type(ClassicPlusMail_DB) ~= "table" then ClassicPlusMail_DB = {} end
    local d = ClassicPlusMail_DB
    d.alts = d.alts or {}
    d.recent = d.recent or {}
    d.alts[realm()] = d.alts[realm()] or {}
    d.recent[realm()] = d.recent[realm()] or {}
    return d
end

-- Remember this character so the others can mail it by name.
function P:RememberMe()
    local _, class = UnitClass("player")
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    db().alts[realm()][me()] = { class = class, level = UnitLevel("player"), faction = faction }
end

function P:RememberRecipient(name)
    if not name or name == "" then return end
    local list = db().recent[realm()]
    for i = getn(list), 1, -1 do
        if strlower(list[i]) == strlower(name) then table.remove(list, i) end
    end
    table.insert(list, 1, name)
    while getn(list) > 20 do table.remove(list) end
end

-- -- Inbox reading ---------------------------------------------------------------------------

-- One letter as a table (nil when the index is past the end).
function P.Letter(i)
    if i < 1 or i > (GetInboxNumItems() or 0) then return nil end
    local _, _, sender, subject, money, cod, days, hasItem, wasRead, wasReturned, textCreated, canReply = GetInboxHeaderInfo(i)
    local l = {
        index = i, sender = sender, subject = subject or "", money = money or 0, cod = cod or 0, days = days,
        hasItem = hasItem and true or false, read = wasRead, returned = wasReturned and true or false,
        canReply = canReply and true or false,
    }
    if hasItem then
        local name, tex, count, quality = GetInboxItem(i)
        l.itemName, l.itemIcon, l.itemCount, l.itemQuality = name, tex, count or 1, quality
    end
    return l
end

-- Room in the bags for an item (a free slot, or a stack of the same item with space).
local function bagRoomFor(name, count)
    local free = 0
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local tex, have = GetContainerItemInfo(bag, slot)
            if not tex then
                free = free + 1
            elseif name then
                local link = GetContainerItemLink(bag, slot)
                local _, _, n = strfind(link or "", "%[(.-)%]")
                if n == name then
                    local _, _, _, _, _, _, stack = GetItemInfo(link)
                    if stack and (have or 1) + (count or 1) <= stack then return true end
                end
            end
        end
    end
    return free > 0, free
end
P.BagRoomFor = bagRoomFor

-- -- Selection (checkboxes on the inbox rows) --------------------------------------------------

P.selected = {}

function P:SelectedCount()
    local n = 0
    for i in pairs(self.selected) do if i <= (GetInboxNumItems() or 0) then n = n + 1 end end
    return n
end

function P:ClearSelection()
    self.selected = {}
    self:UpdateChecks()
end

-- -- Jobs: open / return, one server request at a time ---------------------------------------
-- job = { kind = "open"|"return", only = {index=true} or nil, cod = bool, i = next index,
--         money, items, codPaid, skippedCod, codTotal, kept, waiting, paused }

P.job = nil

local function finishText(job)
    if job.kind == "return" then
        if job.returned == 0 then return "Nothing to return." end
        return "Returned " .. plural(job.returned, "letter") .. "."
    end
    local parts = {}
    if job.money > 0 then table.insert(parts, Coins(job.money)) end
    if job.items > 0 then table.insert(parts, plural(job.items, "item")) end
    local text
    if parts[1] then
        text = "Collected " .. table.concat(parts, " and ")
        if job.codPaid > 0 then text = text .. " (paid " .. Coins(job.codPaid) .. " cash on delivery)" end
        text = text .. "."
    else
        text = "Nothing to collect."
    end
    if job.skippedCod > 0 then
        text = text .. " Skipped " .. plural(job.skippedCod, "cash-on-delivery letter") .. " (" .. Coins(job.codTotal)
            .. "): Shift-click Open All to pay and open " .. ((job.skippedCod == 1) and "it" or "them") .. "."
    end
    if job.stoppedFull then text = text .. " Your bags are full." end
    return text
end

function P:Start(kind, onlySelected, payCod)
    if not active() or not (MailFrame and MailFrame:IsVisible()) then return end
    if self.job then return end
    local only
    if onlySelected then
        only = {}
        local any = false
        for i in pairs(self.selected) do only[i] = true; any = true end
        if not any then
            self:Status("Tick some letters first.")
            return
        end
    end
    self.job = {
        kind = kind, only = only, cod = payCod and true or false, i = GetInboxNumItems() or 0,
        money = 0, items = 0, codPaid = 0, skippedCod = 0, codTotal = 0, returned = 0,
        total = GetInboxNumItems() or 0, done = 0,
    }
    self.stepAt = 0
    self:UpdateButtons()
    self:Step()
end

function P:Stop(reason)
    local job = self.job
    if not job then return end
    self.job = nil
    local text = finishText(job)
    if reason then text = reason .. " " .. text end
    self.lastSummary = text
    self:Status(text)
    if W:Setting(ID, "summary", true) then say(text) end
    self.selected = {}
    self:UpdateButtons()
    self:Scan()
end

-- Ask the server for the next thing, or finish. Called again after each MAIL_INBOX_UPDATE.
function P:Step()
    local job = self.job
    if not job then return end
    if not (MailFrame and MailFrame:IsVisible()) then self:Stop("Mailbox closed.") return end
    while job.i >= 1 do
        local i = job.i
        local l = P.Letter(i)
        local wanted = l and (not job.only or job.only[i])
        if not wanted then
            job.i = i - 1
        elseif job.kind == "return" then
            if l.returned or not l.canReply or not l.sender then
                job.i = i - 1
            else
                job.before = GetInboxNumItems()
                job.waiting = "return"
                job.returned = job.returned + 1
                self.stepAt = GetTime()
                ReturnInboxItem(i)
                self:Status("Returning letters... " .. job.returned .. " sent back.")
                return
            end
        elseif l.cod > 0 and l.hasItem and not job.cod then
            job.skippedCod = job.skippedCod + 1
            job.codTotal = job.codTotal + l.cod
            job.i = i - 1
        elseif l.money > 0 then
            job.before = GetInboxNumItems()
            job.waiting = "money"
            job.pending = l.money
            self.stepAt = GetTime()
            TakeInboxMoney(i)
            self:Progress()
            return
        elseif l.hasItem then
            local room = bagRoomFor(l.itemName, l.itemCount)
            if not room then
                job.paused = true
                self:Status("Your bags are full. Make room and Open All carries on.")
                self:UpdateButtons()
                return
            end
            if l.cod > 0 and GetMoney() < l.cod then
                job.skippedCod = job.skippedCod + 1
                job.codTotal = job.codTotal + l.cod
                job.i = i - 1
            else
                job.before = GetInboxNumItems()
                job.waiting = "item"
                job.pendingCod = l.cod
                job.pendingCount = l.itemCount or 1
                self.stepAt = GetTime()
                TakeInboxItem(i)
                self:Progress()
                return
            end
        else
            job.i = i - 1
        end
    end
    self:Stop()
end

-- MAIL_INBOX_UPDATE: the server answered (or the inbox changed); account for it and carry on
-- on the next frame.
function P:OnInboxUpdate()
    local job = self.job
    if job and job.waiting then
        local l = P.Letter(job.i)
        local gone = (GetInboxNumItems() or 0) < (job.before or 0)
        local ok = false
        if job.waiting == "money" then
            ok = gone or not l or l.money == 0
            if ok then job.money = job.money + (job.pending or 0) end
        elseif job.waiting == "item" then
            ok = gone or not l or not l.hasItem
            if ok then
                job.items = job.items + 1
                job.codPaid = job.codPaid + (job.pendingCod or 0)
            end
        elseif job.waiting == "return" then
            ok = true
        end
        if not ok then return end      -- an unrelated update; keep waiting for ours
        job.waiting = nil
        if gone or job.kind == "return" then job.i = job.i - 1 end
        job.next = true                -- one request per update: the next goes out next frame
    end
    if not job then
        -- the inbox changed under us (a letter taken by hand): ticks may now point elsewhere
        local n = GetInboxNumItems() or 0
        if n ~= self.lastCount then self.selected = {} end
    end
    self:Scan()
end

function P:Progress()
    local job = self.job
    if not job then return end
    local parts = {}
    if job.money > 0 then table.insert(parts, Coins(job.money)) end
    if job.items > 0 then table.insert(parts, plural(job.items, "item")) end
    self:Status("Opening... " .. (job.total - job.i + 1) .. " of " .. job.total
        .. (parts[1] and ("  |cff9a9aa6" .. table.concat(parts, ", ") .. "|r") or ""))
end

-- -- Panel beside the mailbox ---------------------------------------------------------------------

local panel = CreateFrame("Frame", "Mail_Panel", MailFrame or UIParent)
P.panel = panel
UI.Skin(panel, "panel")
panel:SetWidth(232)
panel:SetHeight(400)
panel:EnableMouse(true)
if MailFrame then
    panel:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", -34, -14)
else
    panel:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
end
panel:Hide()

local strip = panel:CreateTexture(nil, "ARTWORK")
strip:SetPoint("TOPLEFT", panel, "TOPLEFT", 3, -3)
strip:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -3, -3)
strip:SetHeight(22)
UI.Gradient(strip, 0.21, 0.21, 0.23, 0.11, 0.11, 0.12)
local stripIcon = panel:CreateTexture(nil, "OVERLAY")
stripIcon:SetWidth(14)
stripIcon:SetHeight(14)
stripIcon:SetPoint("LEFT", strip, "LEFT", 5, 0)
stripIcon:SetTexture(LETTER_ICON)
stripIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
local stripTitle = UI.Label(panel, 11, { 0.95, 0.93, 0.88 }, "OUTLINE")
stripTitle:SetPoint("LEFT", stripIcon, "RIGHT", 6, 0)
stripTitle:SetText("Mail")
local overview = UI.Label(panel, 10, UI.MUTED)
overview:SetPoint("RIGHT", strip, "RIGHT", -6, 0)
overview:SetJustifyH("RIGHT")

local function wideButton(text, w, onClick)
    return UI.Button(panel, text, w, 20, onClick)
end

local openAll = wideButton("Open All", 104, function()
    if P.job then P:Stop("Stopped.") return end
    if IsShiftKeyDown() then P:ConfirmCod(false) else P:Start("open", false, false) end
end)
openAll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -32)
local returnAll = wideButton("Return All", 104, function()
    if P.job then return end
    P:ConfirmReturn(false)
end)
returnAll:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -32)
local openSel = wideButton("Open Ticked", 104, function()
    if P.job then return end
    if IsShiftKeyDown() then P:ConfirmCod(true) else P:Start("open", true, false) end
end)
openSel:SetPoint("TOPLEFT", openAll, "BOTTOMLEFT", 0, -4)
local returnSel = wideButton("Return Ticked", 104, function()
    if P.job then return end
    P:ConfirmReturn(true)
end)
returnSel:SetPoint("TOPRIGHT", returnAll, "BOTTOMRIGHT", 0, -4)
P.buttons = { openAll = openAll, returnAll = returnAll, openSel = openSel, returnSel = returnSel }

local function tip(b, title, line)
    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 0.82, 0)
        GameTooltip:AddLine(line, 0.85, 0.85, 0.85, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
tip(openAll, "Open All", "Takes the money and the item from every letter. Letters that only hold text stay in your inbox. Shift-click to also pay for cash-on-delivery letters.")
tip(returnAll, "Return All", "Sends every letter from a player back to its sender, attachments and all.")
tip(openSel, "Open Ticked", "Like Open All, for the letters you ticked in the inbox.")
tip(returnSel, "Return Ticked", "Sends the ticked letters back to their senders.")

local selInfo = UI.Label(panel, 10, UI.MUTED)
selInfo:SetPoint("TOPLEFT", openSel, "BOTTOMLEFT", 2, -6)
local selAll = CreateFrame("Button", nil, panel)
selAll:SetHeight(14)
selAll:SetWidth(44)
selAll:SetPoint("TOPRIGHT", returnSel, "BOTTOMRIGHT", -46, -5)
local selAllText = UI.Label(selAll, 10, UI.ACCENT)
selAllText:SetPoint("RIGHT", selAll, "RIGHT", 0, 0)
selAllText:SetJustifyH("RIGHT")
selAllText:SetText("All")
selAll:SetScript("OnClick", function()
    for i = 1, (GetInboxNumItems() or 0) do P.selected[i] = true end
    P:UpdateChecks()
end)
local selNone = CreateFrame("Button", nil, panel)
selNone:SetHeight(14)
selNone:SetWidth(44)
selNone:SetPoint("TOPRIGHT", returnSel, "BOTTOMRIGHT", 0, -5)
local selNoneText = UI.Label(selNone, 10, UI.ACCENT)
selNoneText:SetPoint("RIGHT", selNone, "RIGHT", 0, 0)
selNoneText:SetJustifyH("RIGHT")
selNoneText:SetText("None")
selNone:SetScript("OnClick", function() P:ClearSelection() end)

local div1 = UI.Divider(panel)
div1:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -104)
div1:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -104)

local status = UI.Label(panel, 10, { 0.92, 0.92, 0.95 })
status:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -112)
status:SetWidth(212)
P.statusText = status

function P:Status(text)
    status:SetText(text or "")
end

local div2 = UI.Divider(panel)
div2:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -146)
div2:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -146)

local attachTitle = UI.Label(panel, 10, UI.MUTED, "OUTLINE")
attachTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -154)
attachTitle:SetText("ATTACHMENTS")

local search = UI.SearchBox(panel, {
    name = "Mail_Search", width = 212, placeholder = "Find an item, sender or subject",
    onChange = function(t) P.filter = strlower(t or ""); P:FillList() end,
})
search:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -170)

local list = UI.ScrollList(panel, {
    name = "Mail_List", width = 216, height = 198, rowHeight = 22,
    build = function(row)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.icon = UI.IconBox(row, 18)
        row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.name = UI.Label(row, 10)
        row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 22, -1)
        row.name:SetWidth(150)
        row.sub = UI.Label(row, 9, UI.MUTED)
        row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -1)
        row.sub:SetWidth(186)
        row.right = UI.Label(row, 10, { 1, 1, 1 })
        row.right:SetPoint("TOPRIGHT", row, "TOPRIGHT", -2, -1)
        row.right:SetJustifyH("RIGHT")
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(row)
        hl:SetTexture(1, 0.82, 0, 0.08)
        row:SetScript("OnClick", function() if this.item then P:TakeOne(this.item.index) end end)
        row:SetScript("OnEnter", function()
            local it = this.item
            if not it then return end
            GameTooltip:SetOwner(this, "ANCHOR_LEFT")
            if GameTooltip.SetInboxItem and it.hasItem then
                GameTooltip:SetInboxItem(it.index)
            else
                GameTooltip:SetText(it.itemName or it.subject, 1, 1, 1)
            end
            GameTooltip:AddLine("From " .. (it.sender or "?") .. ": " .. (it.subject or ""), 0.7, 0.7, 0.75, 1)
            if it.cod > 0 then GameTooltip:AddLine("Cash on delivery: " .. UI.CoinText(it.cod), 1, 0.5, 0.4) end
            GameTooltip:AddLine("Click to take it.", 0.4, 0.9, 0.4)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end,
    update = function(row, it)
        row.icon.icon:SetTexture(it.itemIcon or "Interface\\Icons\\INV_Misc_Coin_01")
        if it.hasItem then
            local hex = QUALITY_HEX[it.itemQuality or 1] or "ffffffff"
            row.name:SetText("|c" .. hex .. (it.itemName or "?") .. "|r" .. ((it.itemCount or 1) > 1 and (" |cffb0b0b8x" .. it.itemCount .. "|r") or ""))
        else
            row.name:SetText("|cffffd100Money|r")
        end
        local days = it.days and floor(it.days) or 0
        row.sub:SetText("from " .. (it.sender or "?") .. "  |cff707078" .. (days >= 1 and plural(days, "day") or "less than a day") .. " left|r")
        if it.cod > 0 then
            row.right:SetText("|cffff7060COD|r " .. Coins(it.cod))
        elseif it.money > 0 then
            row.right:SetText(Coins(it.money))
        else
            row.right:SetText("")
        end
    end,
})
list:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -194)
P.list = list
local empty = UI.Label(panel, 10, UI.MUTED)
empty:SetPoint("TOP", list, "TOP", 0, -30)
empty:SetJustifyH("CENTER")
empty:SetWidth(200)

-- Take one letter's money and item (from the attachment list).
function P:TakeOne(i)
    if self.job then return end
    local l = P.Letter(i)
    if not l then return end
    if l.cod > 0 and l.hasItem then
        StaticPopup_Show("CLASSICPLUS_MAIL_COD", Coins(l.cod), plural(1, "letter"), { cod = true, only = { [i] = true } })
        return
    end
    self.selected = { [i] = true }
    self:Start("open", true, false)
end

-- -- Inbox scan & list ----------------------------------------------------------------------------

P.letters = {}

function P:Scan()
    local n = GetInboxNumItems and GetInboxNumItems() or 0
    self.lastCount = n
    local letters, money, items, cod = {}, 0, 0, 0
    for i = 1, n do
        local l = P.Letter(i)
        if l then
            table.insert(letters, l)
            money = money + l.money
            if l.hasItem then items = items + 1 end
            if l.cod > 0 then cod = cod + 1 end
        end
    end
    self.letters = letters
    if n == 0 then
        overview:SetText("Empty")
    else
        local parts = { plural(n, "letter") }
        if money > 0 then table.insert(parts, Coins(money)) end
        if items > 0 then table.insert(parts, plural(items, "item")) end
        overview:SetText(table.concat(parts, "  "))
    end
    self:FillList()
    self:UpdateChecks()
    self:UpdateButtons()
end

function P:FillList()
    local f = self.filter
    local out = {}
    for _, l in ipairs(self.letters) do
        if l.hasItem or l.money > 0 then
            local hay = strlower((l.itemName or "") .. " " .. (l.sender or "") .. " " .. (l.subject or ""))
            if not f or f == "" or strfind(hay, f, 1, 1) then table.insert(out, l) end
        end
    end
    list:SetItems(out)
    if out[1] then
        empty:SetText("")
    elseif f and f ~= "" then
        empty:SetText("Nothing in your inbox matches \"" .. f .. "\".")
    else
        empty:SetText("No money or items waiting.")
    end
end

function P:UpdateButtons()
    local busy = self.job ~= nil
    openAll:SetText(busy and "Stop" or "Open All")
    local sel = self:SelectedCount()
    selInfo:SetText(sel > 0 and (sel .. " ticked") or "Tick letters in the inbox")
    for _, b in ipairs({ returnAll, openSel, returnSel }) do
        if busy then b:Disable() else b:Enable() end
    end
    if not busy and sel == 0 then openSel:Disable(); returnSel:Disable() end
end

-- -- Confirmations ------------------------------------------------------------------------------

StaticPopupDialogs["CLASSICPLUS_MAIL_COD"] = {
    text = "Pay %s to open %s sent cash on delivery?",
    button1 = "Pay", button2 = "Cancel",
    OnAccept = function(data)
        if not data then return end
        if data.only then P.selected = data.only end
        P:Start("open", data.only ~= nil, true)
    end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}
StaticPopupDialogs["CLASSICPLUS_MAIL_RETURN"] = {
    text = "Send %s back to the sender?",
    button1 = "Return", button2 = "Cancel",
    OnAccept = function(data) P:Start("return", data and data.only and true or false, false) end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

function P:ConfirmCod(onlySelected)
    local cod, n = 0, 0
    for i = 1, (GetInboxNumItems() or 0) do
        local l = P.Letter(i)
        if l and l.cod > 0 and l.hasItem and (not onlySelected or self.selected[i]) then
            cod = cod + l.cod
            n = n + 1
        end
    end
    if n == 0 then
        self:Start("open", onlySelected, false)
        return
    end
    local only
    if onlySelected then only = {} for i in pairs(self.selected) do only[i] = true end end
    StaticPopup_Show("CLASSICPLUS_MAIL_COD", Coins(cod), plural(n, "letter"), { only = only })
end

function P:ConfirmReturn(onlySelected)
    local n = 0
    for i = 1, (GetInboxNumItems() or 0) do
        local l = P.Letter(i)
        if l and l.canReply and not l.returned and l.sender and (not onlySelected or self.selected[i]) then n = n + 1 end
    end
    if n == 0 then
        self:Status(onlySelected and "None of the ticked letters can be returned." or "No letters from players to return.")
        return
    end
    StaticPopup_Show("CLASSICPLUS_MAIL_RETURN", plural(n, "letter"), nil, { only = onlySelected })
end

-- -- Checkboxes on the stock inbox rows ---------------------------------------------------------

P.checks = {}
local ROWS = INBOXITEMS_TO_DISPLAY or 7

local function makeCheck(i)
    local row = getglobal("MailItem" .. i)
    if not row then return nil end
    local ok, c = pcall(CreateFrame, "CheckButton", "Mail_Check" .. i, row, "UICheckButtonTemplate")
    if not ok or not c then c = CreateFrame("CheckButton", "Mail_Check" .. i, row) end
    c:SetWidth(18)
    c:SetHeight(18)
    local btn = getglobal("MailItem" .. i .. "Button")
    if btn then c:SetPoint("RIGHT", btn, "LEFT", -1, 0) else c:SetPoint("LEFT", row, "LEFT", 0, 0) end
    c:SetFrameLevel(row:GetFrameLevel() + 3)
    c:SetScript("OnClick", function()
        local idx = this.index
        if not idx then return end
        if this:GetChecked() then P.selected[idx] = true else P.selected[idx] = nil end
        P:UpdateButtons()
    end)
    c:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Tick to open or return this letter with the others.", 1, 1, 1, 1, 1)
        GameTooltip:Show()
    end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return c
end

function P:UpdateChecks()
    local show = opt("checkboxes")
    local page = (InboxFrame and InboxFrame.pageNum) or 1
    local n = GetInboxNumItems and GetInboxNumItems() or 0
    for i = 1, ROWS do
        local c = self.checks[i]
        if not c and show then
            c = makeCheck(i)
            self.checks[i] = c
        end
        if c then
            local idx = (page - 1) * ROWS + i
            c.index = idx
            if show and idx <= n then
                c:SetChecked(self.selected[idx] and 1 or nil)
                c:Show()
            else
                c:Hide()
            end
        end
    end
    self:UpdateButtons()
end

-- -- Sending: Alt-click items, several letters, name suggestions ------------------------------

P.outbox = {}

local function sendTabShown()
    return SendMailFrame and SendMailFrame:IsVisible()
end

local function itemAt(bag, slot)
    local tex, count = GetContainerItemInfo(bag, slot)
    if not tex then return nil end
    local link = GetContainerItemLink(bag, slot)
    local _, _, name = strfind(link or "", "%[(.-)%]")
    return { bag = bag, slot = slot, icon = tex, count = count or 1, link = link, name = name or "?" }
end

-- Alt-click on a bag slot while the mailbox is open: attach it (or queue it for its own letter).
function P:AltClick(bag, slot)
    if not (opt("altClick") and MailFrame and MailFrame:IsVisible()) then return false end
    if not IsAltKeyDown() then return false end
    local it = itemAt(bag, slot)
    if not it then return true end
    if not sendTabShown() then
        if MailFrameTab_OnClick then MailFrameTab_OnClick(2) end
    end
    for _, o in ipairs(self.outbox) do
        if o.bag == bag and o.slot == slot then return true end      -- already queued
    end
    local attached = GetSendMailItem and GetSendMailItem()
    if not attached and not self.outbox[1] then
        if CursorHasItem and CursorHasItem() then ClearCursor() end
        PickupContainerItem(bag, slot)
        ClickSendMailItemButton()
        self:SuggestSubject(it.name, it.count)
    elseif getn(self.outbox) >= MAX_OUTBOX then
        say("That's as many letters as one send can make (" .. (MAX_OUTBOX + 1) .. ").")
    else
        table.insert(self.outbox, it)
        if PlaySound then PlaySound("igMainMenuOptionCheckBoxOn") end
    end
    self:UpdateOutbox()
    return true
end

function P:SuggestSubject(name, count)
    local sub = SendMailSubjectEditBox
    if sub and (sub:GetText() or "") == "" and name then
        sub:SetText(name .. ((count or 1) > 1 and (" x" .. count) or ""))
    end
end

-- The queue strip under the send form: one icon per extra letter, click to drop it.
local outFrame = CreateFrame("Frame", "Mail_Outbox", SendMailFrame or panel)
UI.Skin(outFrame, "panel")
outFrame:SetWidth(232)
outFrame:SetHeight(64)
outFrame:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 0, -4)
outFrame:Hide()
local outTitle = UI.Label(outFrame, 10, UI.ACCENT, "OUTLINE")
outTitle:SetPoint("TOPLEFT", outFrame, "TOPLEFT", 8, -7)
local outHint = UI.Label(outFrame, 9, UI.MUTED)
outHint:SetPoint("BOTTOMLEFT", outFrame, "BOTTOMLEFT", 8, 6)
outHint:SetText("Alt-click items in your bags to add them. Click one to take it off.")
outHint:SetWidth(216)
P.outIcons = {}

function P:UpdateOutbox()
    local n = getn(self.outbox)
    local attached = GetSendMailItem and GetSendMailItem()
    if n == 0 or not opt("altClick") then outFrame:Hide() return end
    local letters = n + (attached and 1 or 0)
    outTitle:SetText(plural(letters, "letter") .. " to send, one item each")
    for i = 1, MAX_OUTBOX do
        local b = self.outIcons[i]
        local it = self.outbox[i]
        if it and not b then
            b = CreateFrame("Button", "Mail_OutboxItem" .. i, outFrame)
            b:SetWidth(18)
            b:SetHeight(18)
            b:SetPoint("TOPLEFT", outFrame, "TOPLEFT", 8 + (i - 1) * 19, -21)
            b.box = UI.IconBox(b, 18)
            b.box:SetPoint("CENTER", b, "CENTER", 0, 0)
            b:SetScript("OnClick", function() table.remove(P.outbox, this.i) P:UpdateOutbox() end)
            b:SetScript("OnEnter", function()
                local o = P.outbox[this.i]
                if not o then return end
                GameTooltip:SetOwner(this, "ANCHOR_TOP")
                GameTooltip:SetBagItem(o.bag, o.slot)
                GameTooltip:AddLine("Click to take it off the list.", 0.4, 0.9, 0.4)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            self.outIcons[i] = b
        end
        if b then
            b.i = i
            if it then b.box.icon:SetTexture(it.icon) b:Show() else b:Hide() end
        end
    end
    outFrame:Show()
end

-- Several letters, one after the other: each waits for MAIL_SEND_SUCCESS.
P.sending = nil

-- The money typed into the send form, as the stock Send button reads it: copper, isCOD.
local function formMoney()
    if not (MoneyInputFrame_GetCopper and SendMailMoney) then
        local cod = GetSendMailCOD and GetSendMailCOD() or 0
        if cod > 0 then return cod, true end
        return GetSendMailMoney and GetSendMailMoney() or 0, false
    end
    local copper = MoneyInputFrame_GetCopper(SendMailMoney) or 0
    local cod = SendMailCODButton and SendMailCODButton:GetChecked()
    return copper, cod and true or false
end

function P:SendQueued()
    local to = W.Trim(SendMailNameEditBox and SendMailNameEditBox:GetText() or "")
    if to == "" then say("Who is it for? Type a name first.") return true end
    local subject = SendMailSubjectEditBox and SendMailSubjectEditBox:GetText() or ""
    local body = SendMailBodyEditBox and SendMailBodyEditBox:GetText() or ""
    local letters = {}
    if GetSendMailItem() then table.insert(letters, { attached = true }) end
    for _, o in ipairs(self.outbox) do table.insert(letters, o) end
    local copper, isCod = formMoney()
    if isCod and copper > 0 and getn(letters) > 1 then
        say("Cash on delivery works with one letter at a time. Take the extra items off the list first.")
        return true
    end
    if subject == "" then
        local first = letters[1]
        subject = first and first.name or "Items"
        if first and first.attached then subject = (GetSendMailItem()) or "Items" end
    end
    self.sending = { to = to, subject = subject, body = body, letters = letters, i = 0, total = getn(letters), sent = 0,
        money = (not isCod) and copper or 0 }
    self.outbox = {}
    self:UpdateOutbox()
    self:SendNext()
    return true
end

function P:SendNext()
    local s = self.sending
    if not s then return end
    s.i = s.i + 1
    local l = s.letters[s.i]
    if not l then
        self.sending = nil
        self:RememberRecipient(s.to)
        if W:Setting(ID, "summary", true) then say("Sent " .. plural(s.sent, "letter") .. " to " .. s.to .. ".") end
        if SendMailFrame_Reset then SendMailFrame_Reset() end
        return
    end
    if not l.attached then
        local it = itemAt(l.bag, l.slot)
        if not it or it.link ~= l.link then
            -- moved or gone since it was queued; skip it
            return self:SendNext()
        end
        if CursorHasItem and CursorHasItem() then ClearCursor() end
        PickupContainerItem(l.bag, l.slot)
        ClickSendMailItemButton()
    end
    -- the money goes with the first letter only
    if SetSendMailMoney then SetSendMailMoney((s.i == 1) and s.money or 0) end
    s.waiting = true
    s.at = GetTime()
    SendMail(s.to, s.subject .. " (" .. s.i .. "/" .. s.total .. ")", s.body)
end

-- Remember recipients of ordinary sends too.
function P:OnSendSuccess()
    local s = self.sending
    if s and s.waiting then
        s.waiting = nil
        s.sent = s.sent + 1
        s.next = true
        return
    end
    if self.lastTo then self:RememberRecipient(self.lastTo) self.lastTo = nil end
end

function P:OnSendFailed()
    local s = self.sending
    if s then
        self.sending = nil
        say("Sending stopped after " .. plural(s.sent, "letter") .. ": the server refused letter " .. s.i .. ".")
    end
end

-- -- Name suggestions ---------------------------------------------------------------------------

local suggest = CreateFrame("Frame", "Mail_Suggest", SendMailFrame or UIParent)
UI.Skin(suggest, "raised")
suggest:SetWidth(170)
suggest:SetFrameStrata("DIALOG")
suggest:Hide()
if SendMailNameEditBox then
    suggest:SetPoint("TOPLEFT", SendMailNameEditBox, "BOTTOMLEFT", -6, -2)
end
suggest.rows = {}
local SUGGEST_ROWS = 6
local TAG = { alt = "your character", recent = "mailed before", friend = "friend", guild = "guild" }

function P:Candidates(prefix)
    prefix = strlower(prefix or "")
    if prefix == "" then return {} end
    local out, seen = {}, {}
    local myFaction = UnitFactionGroup and UnitFactionGroup("player")
    local function add(name, source, class)
        if not name or name == "" then return end
        local low = strlower(name)
        if seen[low] or low == strlower(me()) then return end
        if strsub(low, 1, strlen(prefix)) ~= prefix then return end
        seen[low] = true
        table.insert(out, { name = name, source = source, class = class })
    end
    local alts = db().alts[realm()]
    local names = {}
    for n, info in pairs(alts) do
        if not (info.faction and myFaction and info.faction ~= myFaction) then table.insert(names, n) end
    end
    table.sort(names)
    for _, n in ipairs(names) do add(n, "alt", alts[n].class) end
    for _, n in ipairs(db().recent[realm()]) do add(n, "recent") end
    for i = 1, (GetNumFriends and GetNumFriends() or 0) do
        local n, _, class = GetFriendInfo(i)
        add(n, "friend", class)
    end
    if IsInGuild and IsInGuild() and GetGuildRosterInfo then
        local count = GetNumGuildMembers() or 0
        for i = 1, count do
            local n, _, _, _, class = GetGuildRosterInfo(i)
            add(n, "guild", class)
        end
    end
    return out
end

local function classColour(class)
    if not class then return 1, 1, 1 end
    local token = string.upper(class)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

function P:Accept(name)
    if not SendMailNameEditBox then return end
    self.accepting = true
    SendMailNameEditBox:SetText(name)
    self.accepting = nil
    suggest:Hide()
    if SendMailSubjectEditBox and SendMailSubjectEditBox.SetFocus then SendMailSubjectEditBox:SetFocus() end
end

function P:ShowSuggestions(text)
    if not opt("autocomplete") or self.accepting then suggest:Hide() return end
    local list = self:Candidates(text)
    -- an exact match on its own needs no list
    if not list[1] or (not list[2] and strlower(list[1].name) == strlower(text or "")) then
        suggest:Hide()
        self.suggestions = list
        return
    end
    self.suggestions = list
    local n = math.min(getn(list), SUGGEST_ROWS)
    for i = 1, n do
        local r = suggest.rows[i]
        if not r then
            r = CreateFrame("Button", "Mail_SuggestRow" .. i, suggest)
            r:SetHeight(16)
            r:SetWidth(162)
            r:SetPoint("TOPLEFT", suggest, "TOPLEFT", 4, -4 - (i - 1) * 16)
            r.name = UI.Label(r, 10)
            r.name:SetPoint("LEFT", r, "LEFT", 4, 0)
            r.tag = UI.Label(r, 9, UI.MUTED)
            r.tag:SetPoint("RIGHT", r, "RIGHT", -4, 0)
            r.tag:SetJustifyH("RIGHT")
            local hl = r:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(r)
            hl:SetTexture(1, 0.82, 0, 0.12)
            r:SetScript("OnClick", function() P:Accept(this.value) end)
            suggest.rows[i] = r
        end
        local c = list[i]
        r.value = c.name
        r.name:SetText(c.name)
        r.name:SetTextColor(classColour(c.class))
        r.tag:SetText(TAG[c.source] or "")
        r:Show()
    end
    for i = n + 1, getn(suggest.rows) do suggest.rows[i]:Hide() end
    suggest:SetHeight(n * 16 + 8)
    suggest:Show()
end

local hookedName = false
local function hookNameBox()
    local e = SendMailNameEditBox
    if hookedName or not e then return end
    hookedName = true
    local origChanged = e:GetScript("OnTextChanged")
    e:SetScript("OnTextChanged", function()
        if origChanged then origChanged() end
        P:ShowSuggestions(e:GetText())
    end)
    local origTab = e:GetScript("OnTabPressed")
    e:SetScript("OnTabPressed", function()
        local s = P.suggestions
        if suggest:IsVisible() and s and s[1] then P:Accept(s[1].name) return end
        if origTab then origTab() end
    end)
    local origEnter = e:GetScript("OnEnterPressed")
    e:SetScript("OnEnterPressed", function()
        local s = P.suggestions
        if suggest:IsVisible() and s and s[1] then P:Accept(s[1].name) return end
        if origEnter then origEnter() end
    end)
    local origLost = e:GetScript("OnEditFocusLost")
    e:SetScript("OnEditFocusLost", function()
        if origLost then origLost() end
        if not MouseIsOver or not MouseIsOver(suggest) then suggest:Hide() end
    end)
end

-- -- Hooks ----------------------------------------------------------------------------------------

local orig = {}

-- The stock Send button: several queued items become several letters.
if SendMailFrame_SendMail then
    orig.SendMailFrame_SendMail = SendMailFrame_SendMail
    SendMailFrame_SendMail = function()
        if active() and (P.outbox[1] or P.sending) then
            if P.sending then return end
            P:SendQueued()
            return
        end
        P.lastTo = SendMailNameEditBox and W.Trim(SendMailNameEditBox:GetText() or "")
        return orig.SendMailFrame_SendMail()
    end
end

if InboxFrame_Update then
    orig.InboxFrame_Update = InboxFrame_Update
    InboxFrame_Update = function()
        orig.InboxFrame_Update()
        if active() then P:UpdateChecks() end
    end
end

-- Alt-click in the stock bags...
if ContainerFrameItemButton_OnClick then
    orig.ContainerFrameItemButton_OnClick = ContainerFrameItemButton_OnClick
    ContainerFrameItemButton_OnClick = function(button, ignoreModifiers)
        if button == "LeftButton" and not ignoreModifiers and this and this.GetParent and IsAltKeyDown() then
            local bag, slot = this:GetParent():GetID(), this:GetID()
            if P:AltClick(bag, slot) then return end
        end
        return orig.ContainerFrameItemButton_OnClick(button, ignoreModifiers)
    end
end
-- ...and in the Bags window.
Vault = Vault or {}
Vault.clickHooks = Vault.clickHooks or {}
table.insert(Vault.clickHooks, function(b, button)
    if button ~= "RightButton" and b.bag and IsAltKeyDown() then return P:AltClick(b.bag, b.slot) end
end)

-- -- Events ---------------------------------------------------------------------------------------

local ev = CreateFrame("Frame", "Mail_Events")
for _, e in ipairs({ "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "MAIL_SEND_SUCCESS", "MAIL_FAILED",
    "MAIL_SEND_INFO_UPDATE", "BAG_UPDATE", "UI_ERROR_MESSAGE", "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP" }) do
    ev:RegisterEvent(e)
end
ev:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_LEVEL_UP" then
        P:RememberMe()
        return
    end
    if not active() then return end
    if event == "MAIL_SHOW" then
        hookNameBox()
        P.selected = {}
        P.lastSummary = nil
        P:Status("")
        if opt("openAll") then panel:Show() end
        P:Scan()
    elseif event == "MAIL_CLOSED" then
        if P.job then P:Stop("Mailbox closed.") end
        if P.sending then
            P.sending = nil
            say("Sending stopped: the mailbox was closed.")
        end
        P.outbox = {}
        P:UpdateOutbox()
        suggest:Hide()
    elseif event == "MAIL_INBOX_UPDATE" then
        P:OnInboxUpdate()
    elseif event == "MAIL_SEND_SUCCESS" then
        P:OnSendSuccess()
    elseif event == "MAIL_FAILED" then
        P:OnSendFailed()
    elseif event == "MAIL_SEND_INFO_UPDATE" then
        P:UpdateOutbox()
    elseif event == "BAG_UPDATE" then
        local job = P.job
        if job and job.paused then
            local l = P.Letter(job.i)
            if not l or not l.hasItem or bagRoomFor(l.itemName, l.itemCount) then
                job.paused = nil
                job.next = true
            end
        end
    elseif event == "UI_ERROR_MESSAGE" then
        local job = P.job
        if job and job.waiting == "item" and arg1 and strfind(strlower(arg1), "inventory is full", 1, 1) then
            job.waiting = nil
            job.paused = true
            P:Status("Your bags are full. Make room and Open All carries on.")
        end
    end
end)

-- The next request goes out on the frame after the server's answer; a lost answer is asked again.
ev:SetScript("OnUpdate", function()
    local job = P.job
    if job then
        if job.next then
            job.next = nil
            P:Step()
        elseif job.waiting and GetTime() - (P.stepAt or 0) > STEP_TIMEOUT then
            job.waiting = nil
            P:Step()
        end
    end
    local s = P.sending
    if s then
        if s.next then
            s.next = nil
            P:SendNext()
        elseif s.waiting and GetTime() - (s.at or 0) > STEP_TIMEOUT * 2 then
            P.sending = nil
            say("Sending stopped: the server didn't answer.")
        end
    end
end)

-- -- Registration ---------------------------------------------------------------------------------

W:RegisterSchema(ID, {
    title = "Mail - Mailbox",
    icon = LETTER_ICON,
    desc = "Open all your mail in one click, return letters, tick letters to handle a few at once, Alt-click items to mail them, and name suggestions while you type.",
    defaults = { openAll = true, checkboxes = true, altClick = true, autocomplete = true, summary = true },
    options = {
        { key = "openAll", label = "Mail panel", sub = "Open All, Return All and the attachment list beside the mailbox." },
        { key = "checkboxes", label = "Tick boxes on letters", sub = "A box on each inbox row to open or return just those letters." },
        { key = "altClick", label = "Alt-click to attach", sub = "Alt-click an item in your bags to mail it. More items go as one letter each." },
        { key = "autocomplete", label = "Name suggestions", sub = "Your other characters, people you've mailed, friends and guild as you type the name." },
        { key = "summary", label = "Summary in chat", sub = "One line when a run ends: what you collected, returned or sent." },
    },
})

W:RegisterAddon(ID, function(on)
    if not on then
        if P.job then P:Stop("Stopped.") end
        panel:Hide()
        suggest:Hide()
        outFrame:Hide()
    elseif MailFrame and MailFrame:IsVisible() then
        if W:Setting(ID, "openAll", true) then panel:Show() P:Scan() else panel:Hide() end
    end
    P:UpdateChecks()
    P:UpdateOutbox()
end)

SLASH_CPMAIL1 = "/mail"
SlashCmdList["CPMAIL"] = function(msg)
    msg = strlower(W.Trim(msg))
    if not active() then return end
    if not (MailFrame and MailFrame:IsVisible()) then
        say("Open a mailbox first. At a mailbox: |cffffd100/mail open|r opens everything, |cffffd100/mail return|r returns every player's letter.")
        return
    end
    if msg == "open" or msg == "all" then
        P:Start("open", false, false)
    elseif msg == "return" then
        P:ConfirmReturn(false)
    elseif msg == "stop" then
        P:Stop("Stopped.")
    else
        say("|cffffd100/mail open|r takes everything, |cffffd100/mail return|r returns every player's letter, |cffffd100/mail stop|r stops.")
    end
end
