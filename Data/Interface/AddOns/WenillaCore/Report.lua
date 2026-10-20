--[[
    Report.lua  (Classic+ / Open Vanilla)
    "Report…" for players: one shared dialog every addon opens the same way.

        W.Report.Open(targetName [, context])   the dialog (category, a note, the last chat lines)
        W.Report.Submit(category, name, note [, context])   send without the dialog; returns ok, why
        W.Report.Lines(name, n)                 the last n chat lines seen from / to that name

    The report goes up as one ".wnl report <category>,<name>,<note>,<lines>" line (fields escaped:
    "\\" -> "\\\\", "," -> "\\c", newline -> "\\n"; colour codes and links stripped, raw '|' dropped)
    and never longer than one chat line (255 bytes): the note keeps up to NOTE_MAX characters, the
    chat lines take what is left. The client gathers the lines itself from its own chat buffer, so
    a report carries context even on a realm whose server attaches none.

    Rate limit: one report per 30 s and 10 per hour (also enforced server-side). Away from the
    realm's server channel (not greeted yet, or a realm without the hook) a report waits in a
    short queue and goes up at the next greeting; the toast says so.

    The server answers "RP ok,<id>" / "RP err,<reason>" (ratelimit, unknown, dup, off) and tells
    the player about automatic moderation with a plain system line; "/appeal <text>" sends
    ".wnl appeal <text>" (also works typed as ".wnl appeal ..." without the suite).

    The unit menus' "Report…" entry is added by UnitMenu.lua (UnitPopupButtons.WNL_REPORT).

    Lua 5.0 rules (1.12.1 client): no '#', no '%', handlers read this/event/arg1.
]]--

local W = WenillaCore
local UI = W.UI
local R = {}
W.Report = R

local strsub, strfind, strlen, strlower, strupper = string.sub, string.find, string.len, string.lower, string.upper
local getn, tinsert, tremove = table.getn, table.insert, table.remove

R.CATEGORIES = {
    { key = "spam", label = "Spam / advertising" },
    { key = "harassment", label = "Harassment / abuse" },
    { key = "cheating", label = "Cheating / botting" },
    { key = "gold-seller", label = "Gold seller" },
    { key = "name", label = "Offensive name" },
    { key = "other", label = "Something else" },
}
R.MIN_GAP = 30          -- seconds between two reports
R.PER_HOUR = 10
R.LINE_MAX = 255        -- one chat line (the 1.12 limit)
R.NOTE_MAX = 100        -- characters of the note that always fit
R.LINES_WANTED = 8      -- chat lines gathered for the report
R.BUFFER_SIZE = 200     -- chat lines remembered
R.QUEUE_MAX = 5

R.buffer = {}           -- { t, kind, from, to, text } newest last
R.sent = {}             -- times of the reports sent (rate limit)
R.queue = {}            -- lines waiting for the server channel
R.lastResult = nil

local function now() return GetTime and GetTime() or 0 end

local function me() return UnitName and UnitName("player") or "" end

-- -- Text ------------------------------------------------------------------------------------

-- Colour codes and links gone, raw '|' dropped (the client refuses it in a chat line).
function R.Clean(s)
    s = tostring(s or "")
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")
    s = string.gsub(s, "|r", "")
    s = string.gsub(s, "|H[^|]*|h(%[[^%]]*%])|h", "%1")
    s = string.gsub(s, "|H[^|]*|h([^|]*)|h", "%1")
    s = string.gsub(s, "|", "")
    s = string.gsub(s, "[\r\n\t]", " ")
    return s
end

function R.Escape(s)
    s = R.Clean(s)
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, ",", "\\c")
    return s
end

local UNESC = { c = ",", n = "\n" }
function R.Unescape(s)
    s = string.gsub(tostring(s or ""), "\\(.)", function(c) return UNESC[c] or c end)
    return s
end

local function proper(name)
    name = W.Trim(tostring(name or ""))
    if name == "" then return "" end
    local sp = strfind(name, " ", 1, 1)
    if sp then name = strsub(name, 1, sp - 1) end
    return strupper(strsub(name, 1, 1)) .. strlower(strsub(name, 2))
end
R.Proper = proper

function R.IsCategory(key)
    for _, c in ipairs(R.CATEGORIES) do if c.key == key then return true end end
    return false
end

-- -- Chat buffer ------------------------------------------------------------------------------

local KINDS = {
    CHAT_MSG_SAY = "say", CHAT_MSG_YELL = "yell", CHAT_MSG_EMOTE = "emote", CHAT_MSG_CHANNEL = "chan",
    CHAT_MSG_WHISPER = "whisper", CHAT_MSG_WHISPER_INFORM = "whisper", CHAT_MSG_PARTY = "party",
    CHAT_MSG_RAID = "raid", CHAT_MSG_GUILD = "guild", CHAT_MSG_OFFICER = "officer",
}

function R.Remember(ev, text, sender, channel)
    local kind = KINDS[ev]
    if not kind or not text or text == "" then return end
    if strsub(text, 1, 4) == "WNL\t" or strsub(text, 1, 4) == "WNL " then return end
    local from, to = sender, nil
    if ev == "CHAT_MSG_WHISPER_INFORM" then from, to = me(), sender end
    if ev == "CHAT_MSG_WHISPER" then to = me() end
    if kind == "chan" and channel and channel ~= "" then kind = "chan:" .. tostring(channel) end
    tinsert(R.buffer, { t = now(), kind = kind, from = from or "", to = to, text = R.Clean(text) })
    while getn(R.buffer) > R.BUFFER_SIZE do tremove(R.buffer, 1) end
end

-- The last n lines from / to a name, oldest first.
function R.Lines(name, n)
    n = n or R.LINES_WANTED
    local want = strlower(proper(name))
    local picked = {}
    for i = getn(R.buffer), 1, -1 do
        local l = R.buffer[i]
        if strlower(l.from) == want or (l.to and strlower(l.to) == want) then
            tinsert(picked, 1, l)
            if getn(picked) >= n then break end
        end
    end
    return picked
end

-- "[kind] From: text" per line; joined with "\n" (escaped as "\\n" on the wire).
function R.LinesText(lines)
    local out = {}
    for _, l in ipairs(lines) do
        local head = "[" .. l.kind .. "] " .. l.from
        if l.to then head = head .. " > " .. l.to end
        tinsert(out, head .. ": " .. l.text)
    end
    return out
end

-- -- The command line ---------------------------------------------------------------------------

-- "<category>,<name>,<note>,<lines>" cut to fit one chat line with ".wnl report " in front.
function R.Format(category, name, note, lines)
    local head = category .. "," .. proper(name) .. ","
    local room = R.LINE_MAX - strlen(".wnl report ") - strlen(head) - 1   -- the comma before lines
    note = R.Clean(note or "")
    if strlen(note) > R.NOTE_MAX then note = strsub(note, 1, R.NOTE_MAX) end
    local enote = R.Escape(note)
    while strlen(enote) > room and strlen(note) > 0 do
        note = strsub(note, 1, strlen(note) - 1)
        enote = R.Escape(note)
    end
    room = room - strlen(enote)
    local parts = {}
    local used = 0
    -- newest lines first, so the freshest context survives the cut; then back in order
    local texts = R.LinesText(lines or {})
    for i = getn(texts), 1, -1 do
        local e = R.Escape(texts[i])
        local extra = strlen(e) + (getn(parts) > 0 and 2 or 0)
        if used + extra > room then
            if getn(parts) == 0 and room > 12 then
                -- even the latest line is too long: keep its head
                local cut = strsub(texts[i], 1, room - 4)
                e = R.Escape(cut)
                while strlen(e) > room - 1 and strlen(cut) > 0 do
                    cut = strsub(cut, 1, strlen(cut) - 1)
                    e = R.Escape(cut)
                end
                tinsert(parts, 1, e .. "~")
            end
            break
        end
        tinsert(parts, 1, e)
        used = used + extra
    end
    return head .. enote .. "," .. table.concat(parts, "\\n")
end

-- -- Rate limit --------------------------------------------------------------------------------

function R.Allowed()
    local t = now()
    local kept, hour = {}, 0
    for _, x in ipairs(R.sent) do
        if t - x < 3600 then tinsert(kept, x); hour = hour + 1 end
    end
    R.sent = kept
    local last = kept[getn(kept)]
    if last and t - last < R.MIN_GAP then return false, "wait", math.ceil(R.MIN_GAP - (t - last)) end
    if hour >= R.PER_HOUR then return false, "hour" end
    return true
end

-- -- Sending ----------------------------------------------------------------------------------

local function toast(title, text, color)
    if UI and UI.Toast then
        UI.Toast({ title = title, text = text, icon = "Interface\\Icons\\INV_Letter_15", color = color or UI.ACCENT, duration = 6 })
    else
        W.Print(title .. " " .. text)
    end
end

function R.Flush()
    if not W.connected or W.isVanillaMode then return 0 end
    local n = 0
    while R.queue[1] do
        local args = tremove(R.queue, 1)
        if W:SendCommand("report", args) then n = n + 1 end
    end
    if n > 0 then toast("Report sent", n == 1 and "Your saved report went to the moderators." or (n .. " saved reports went to the moderators.")) end
    return n
end

-- ok, why ("wait" + seconds, "hour", "name", "category", "self", "queued")
function R.Submit(category, name, note, context)
    name = proper(name)
    if name == "" then return false, "name" end
    if strlower(name) == strlower(me()) then return false, "self" end
    if not R.IsCategory(category) then return false, "category" end
    local ok, why, secs = R.Allowed()
    if not ok then return false, why, secs end
    note = W.Trim(note or "")
    if context and context ~= "" then note = "[" .. tostring(context) .. "] " .. note end
    local args = R.Format(category, name, note, R.Lines(name))
    tinsert(R.sent, now())
    if W.connected and not W.isVanillaMode then
        W:SendCommand("report", args)
        R.lastResult = nil
        toast("Thanks", "A moderator will look at your report about " .. name .. ".")
        return true
    end
    if getn(R.queue) >= R.QUEUE_MAX then tremove(R.queue, 1) end
    tinsert(R.queue, args)
    toast("Report saved", "Not connected to the realm's server channel; it goes up when you are.", UI and UI.MUTED)
    return true, "queued"
end

local WHY = {
    wait = "Please wait %d seconds between reports.",
    hour = "That is enough reports for this hour; thank you.",
    name = "Who do you want to report?",
    category = "Pick what the report is about.",
    self = "You cannot report yourself.",
}
function R.Why(why, secs)
    local s = WHY[why] or "Could not send the report."
    if why == "wait" then s = string.format(s, secs or R.MIN_GAP) end
    return s
end

-- -- Server answers ---------------------------------------------------------------------------

W:RegisterModule("RP", function(body)
    local f = W.Split(body or "", ",")
    R.lastResult = f[1]
    if f[1] == "err" then
        local why = f[2] or ""
        local msg = "The realm did not take the report"
        if why == "ratelimit" then msg = "The realm says: too many reports; try again later"
        elseif why == "unknown" then msg = "The realm knows no player by that name"
        elseif why == "dup" then msg = "You already reported them a moment ago; it was added to that case"
        elseif why == "off" then msg = "Reports are off on this realm" end
        toast("Report", msg .. ".", UI and UI.MUTED)
    end
end)

-- -- Dialog ------------------------------------------------------------------------------------

local win
local function build()
    if win then return win end
    win = UI.Window("WenillaCore_ReportFrame", { width = 330, height = 372, title = "Report a player", strata = "DIALOG",
        icon = "Interface\\Icons\\INV_Letter_15", point = { "CENTER", UIParent, "CENTER", 0, 60 }, skin = true })
    if UISpecialFrames then tinsert(UISpecialFrames, "WenillaCore_ReportFrame") end
    win:Hide()
    local y = -34
    win.who = UI.Label(win, 12, UI.ACCENT, "OUTLINE")
    win.who:SetPoint("TOPLEFT", win, "TOPLEFT", 14, y)
    win.ctx = UI.Label(win, 10, UI.MUTED)
    win.ctx:SetPoint("LEFT", win.who, "RIGHT", 8, 0)
    y = y - 22
    win.radios = {}
    for i, c in ipairs(R.CATEGORIES) do
        local col = (i - 1) - math.floor((i - 1) / 2) * 2    -- 0 or 1 (no '%')
        local row = math.floor((i - 1) / 2)
        -- a check box that behaves as a radio button (R.Pick unchecks the others)
        local b = CreateFrame("CheckButton", "WenillaCore_ReportCat" .. i, win, "UICheckButtonTemplate")
        b:SetWidth(20); b:SetHeight(20)
        b:SetPoint("TOPLEFT", win, "TOPLEFT", 14 + col * 158, y - row * 20)
        b.key = c.key
        b.label = UI.Label(b, 10, { 0.92, 0.92, 0.95 })
        b.label:SetPoint("LEFT", b, "RIGHT", 4, 0)
        b.label:SetText(c.label)
        b:SetScript("OnClick", function() R.Pick(this.key) end)
        win.radios[i] = b
    end
    y = y - 66
    local l = UI.Label(win, 10, UI.MUTED)
    l:SetPoint("TOPLEFT", win, "TOPLEFT", 14, y)
    l:SetText("What happened? (optional)")
    y = y - 14
    local well = UI.NoteBox(win, "WenillaCore_ReportNote", 302, 40, R.NOTE_MAX)
    well:SetPoint("TOPLEFT", win, "TOPLEFT", 14, y)
    local e = well.edit
    e:SetScript("OnEscapePressed", function() win:Hide() end)
    win.note = e
    y = y - 48
    local l2 = UI.Label(win, 10, UI.MUTED)
    l2:SetPoint("TOPLEFT", win, "TOPLEFT", 14, y)
    l2:SetText("Recent chat with them (sent with the report)")
    y = y - 14
    local box = CreateFrame("Frame", nil, win)
    UI.Skin(box, "inset")
    box:SetWidth(302); box:SetHeight(92)
    box:SetPoint("TOPLEFT", win, "TOPLEFT", 14, y)
    win.lines = UI.Label(box, 9, { 0.8, 0.82, 0.86 })
    win.lines:SetPoint("TOPLEFT", box, "TOPLEFT", 6, -5)
    win.lines:SetWidth(290); win.lines:SetHeight(82)
    if win.lines.SetJustifyV then win.lines:SetJustifyV("TOP") end
    y = y - 98
    win.status = UI.Label(win, 10, { 1, 0.55, 0.45 })
    win.status:SetPoint("TOPLEFT", win, "TOPLEFT", 14, y)
    win.status:SetWidth(302)
    win.send = UI.Button(win, "Send report", 110, 22, function() R.Send() end)
    win.send:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -12, 10)
    win.cancel = UI.Button(win, "Cancel", 80, 22, function() win:Hide() end)
    win.cancel:SetPoint("RIGHT", win.send, "LEFT", -6, 0)
    win:SetScript("OnHide", function() e:ClearFocus() end)
    return win
end

function R.Pick(key)
    if not win then return end
    win.category = key
    for _, b in ipairs(win.radios) do b:SetChecked(b.key == key) end
    win.status:SetText("")
end

function R.Open(targetName, context)
    local name = proper(targetName)
    if name == "" then W.Print("Report: no player named.") return false end
    if strlower(name) == strlower(me()) then W.Print("Report: you cannot report yourself.") return false end
    if not (UI and UI.Window) then return false end
    local f = build()
    f.target, f.context = name, context
    f.who:SetText(name)
    f.ctx:SetText(context and ("from " .. tostring(context)) or "")
    f.note:SetText("")
    f.status:SetText("")
    local texts = R.LinesText(R.Lines(name))
    if texts[1] then
        local shown = {}
        for i = math.max(1, getn(texts) - 5), getn(texts) do
            local t = texts[i]
            if strlen(t) > 70 then t = strsub(t, 1, 68) .. "…" end
            tinsert(shown, t)
        end
        f.lines:SetText(table.concat(shown, "\n"))
    else
        f.lines:SetText("|cff8a8d96(no recent chat with " .. name .. " in this session)|r")
    end
    R.Pick(nil)
    f:Show()
    return true
end

function R.Send()
    if not win or not win:IsShown() then return false end
    if not win.category then win.status:SetText(R.Why("category")) return false end
    local ok, why, secs = R.Submit(win.category, win.target, win.note:GetText() or "", win.context)
    if not ok then win.status:SetText(R.Why(why, secs)) return false end
    win:Hide()
    return true
end

-- -- Unit menu entry (UnitMenu.lua adds WNL_REPORT to the player menus) ----------------------------

if UnitPopupButtons then
    UnitPopupButtons["WNL_REPORT"] = { text = "Report...", dist = 0 }
    local orig = UnitPopup_OnClick
    UnitPopup_OnClick = function()
        if this and this.value == "WNL_REPORT" then
            local dd = UIDROPDOWNMENU_INIT_MENU and getglobal(UIDROPDOWNMENU_INIT_MENU)
            local name = (dd and dd.name) or (dd and (dd.unit or dd.cpUnit) and UnitName(dd.unit or dd.cpUnit)) or (dd and dd.cpName)
            if name then R.Open(name, "menu") end
            return
        end
        if orig then return orig() end
    end
end

-- -- Events, queue flush, slash ---------------------------------------------------------------

local ev = CreateFrame("Frame", "WenillaCore_ReportEvents")
for k in pairs(KINDS) do ev:RegisterEvent(k) end
ev:SetScript("OnEvent", function()
    R.Remember(event, arg1, arg2, arg4)
end)

local origHandshake = W.HandleHandshake
function W:HandleHandshake(payload)
    origHandshake(self, payload)
    if R.queue[1] then R.Flush() end
end

SLASH_WNLREPORT1 = "/report"
SlashCmdList["WNLREPORT"] = function(msg)
    msg = W.Trim(msg or "")
    if msg == "" then
        local t = UnitExists and UnitExists("target") and UnitIsPlayer("target") and UnitName("target")
        if t then R.Open(t, "target") else W.Print("/report <name>  or target a player and /report") end
        return
    end
    R.Open(msg, "slash")
end

SLASH_WNLAPPEAL1 = "/appeal"
SlashCmdList["WNLAPPEAL"] = function(msg)
    msg = R.Clean(W.Trim(msg or ""))
    if msg == "" then W.Print("/appeal <what you want the moderators to know>") return end
    if strlen(msg) > 200 then msg = strsub(msg, 1, 200) end
    if W.connected and not W.isVanillaMode then
        W:SendCommand("appeal", msg)
        W.Print("Appeal sent; a moderator will read it.")
    else
        W.Print("Not connected to the realm's server channel; try again in a moment.")
    end
end
