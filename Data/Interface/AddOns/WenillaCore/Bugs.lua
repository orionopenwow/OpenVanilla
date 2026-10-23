--[[
    Bugs.lua  (WenillaCore)
    The blue bug button, just right of the chat frame: click it, say what went wrong, Send. The
    report goes to the realm as one line and Herald posts it to the Discord #bug-reports forum.

        ".wnl bug <category>,<what happened>,<context>"   (fields escaped as W.Report.Escape does)
    The realm adds who and where (realm/mangos/0014-openvanilla-bug-reports.patch) and answers
        BG ok | BG err,<empty|ratelimit|off>
    The context is gathered here: zone, subzone, map position, target, frame rate and latency,
    whether Herald was playing, and the suite's version.
    One report a minute (the realm also allows 20 a day). A realm that doesn't answer within
    10 seconds doesn't take bug reports; the window says to post in Discord instead.

    Lua 5.0 rules (1.12.1 client): no '#', no '%', handlers read this/event/arg1.
]]--

local W = WenillaCore
local UI = W.UI
local B = {}
W.Bugs = B

local strlen, strsub = string.len, string.sub

B.CATEGORIES = {
    { key = "quest", label = "Quest or NPC" },
    { key = "spell", label = "Spell or ability" },
    { key = "addon", label = "Addon or interface" },
    { key = "graphics", label = "Graphics or sound" },
    { key = "server", label = "Server or lag" },
    { key = "other", label = "Something else" },
}
-- the three tabs: a bug (with a category), feedback, an idea. Feedback and ideas go up the same way with
-- their own category ("feedback" / "idea"); the text starts "Feedback:" / "Idea:" so a realm that only
-- knows the bug categories (it files them as "other") still shows what they are.
B.KINDS = {
    { key = "bug", label = "Bug", ask = "What went wrong? What did you expect?" },
    { key = "feedback", label = "Feedback", ask = "What do you think? What's good, what's not?", tag = "Feedback: " },
    { key = "idea", label = "Idea", ask = "What should we add or change?", tag = "Idea: " },
}
B.HEIGHT = 324               -- the window, on the Bug tab
B.CAT_ROWS = 64               -- the categories' height: Feedback and Idea are that much shorter
B.GAP = 60                    -- seconds between reports
B.WAIT = 10                   -- seconds to wait for the realm's answer
B.LINE_MAX = 255              -- one chat line

local win, button
B.lastSent = nil              -- GetTime() of the last report
B.waiting = nil               -- GetTime() a report went up, until the realm answers

local function escape(s) return W.Report and W.Report.Escape(s) or string.gsub(tostring(s or ""), ",", " ") end

-- where you are and what you're looking at, short
function B.Context()
    local parts = {}
    local zone = GetRealZoneText and GetRealZoneText() or ""
    local sub = GetSubZoneText and GetSubZoneText() or ""
    if zone ~= "" then table.insert(parts, (sub ~= "" and sub ~= zone) and (zone .. " - " .. sub) or zone) end
    if GetPlayerMapPosition then
        if SetMapToCurrentZone and not (WorldMapFrame and WorldMapFrame:IsVisible()) then SetMapToCurrentZone() end
        local x, y = GetPlayerMapPosition("player")
        if x and y and (x > 0 or y > 0) then
            table.insert(parts, string.format("%.1f, %.1f", x * 100, y * 100))
        end
    end
    if UnitExists and UnitExists("target") then
        table.insert(parts, "target " .. (UnitName("target") or "?") .. " (" .. (UnitLevel("target") or "?") .. ")")
    end
    -- how the game was running, for lag reports: frame rate and latency; and whether Herald was
    -- playing the character, as Herald and the player can step on each other
    local perf = {}
    if GetFramerate then table.insert(perf, math.floor(GetFramerate() + 0.5) .. " fps") end
    if GetNetStats then
        local _, _, ms = GetNetStats()
        if ms then table.insert(perf, ms .. " ms") end
    end
    if table.getn(perf) > 0 then table.insert(parts, table.concat(perf, " ")) end
    if Herald_IsPlaying and Herald_IsPlaying() then table.insert(parts, "Herald on") end
    table.insert(parts, "addons " .. (W.version or "?"))
    local ctx = table.concat(parts, " · ")
    if strlen(ctx) > 120 then ctx = strsub(ctx, 1, 120) end
    return ctx
end

-- The command line for a report, cut to one chat line (the text gives way, never the context).
function B.Line(category, text, context)
    local head = "bug " .. category .. ","
    local ctx = "," .. escape(context)
    local body = escape(text)
    local room = B.LINE_MAX - strlen(".wnl ") - strlen(head) - strlen(ctx)
    if strlen(body) > room then
        body = strsub(body, 1, room)
        -- never cut an escape in half
        if strsub(body, -1) == "\\" then body = strsub(body, 1, -2) end
    end
    return head .. body .. ctx
end

local function status(text, ok)
    if not win then return end
    win.status:SetText(text or "")
    if ok then win.status:SetTextColor(0.45, 1, 0.45) else win.status:SetTextColor(1, 0.55, 0.45) end
end

function B.Pick(key)
    if not win then return end
    win.category = key
    for _, b in ipairs(win.radios) do b:SetChecked(b.key == key) end
    status("")
end

function B.Kind(key)
    for _, k in ipairs(B.KINDS) do if k.key == key then return k end end
    return B.KINDS[1]
end

-- switch tab: the categories are for bugs only
function B.SetKind(key)
    if not win then return end
    local kind = B.Kind(key)
    win.kind = kind.key
    for _, t in ipairs(win.tabs) do
        if t.key == kind.key then t:LockHighlight() else t:UnlockHighlight() end
    end
    for _, b in ipairs(win.radios) do if kind.key == "bug" then b:Show() else b:Hide() end end
    win.ask:SetText(kind.ask)
    local bug = kind.key == "bug"
    win.body:ClearAllPoints()
    win.body:SetPoint("TOPLEFT", win, "TOPLEFT", 0, bug and win.bodyY or (win.bodyY + B.CAT_ROWS))
    win:SetHeight(bug and B.HEIGHT or (B.HEIGHT - B.CAT_ROWS))
    status("")
end

function B.Send()
    if not win or not win:IsShown() then return false end
    local text = W.Trim(win.note:GetText() or "")
    if text == "" then status("Say what went wrong first.") return false end
    if B.lastSent and GetTime() - B.lastSent < B.GAP then
        status("One report a minute: try again in " .. math.ceil(B.GAP - (GetTime() - B.lastSent)) .. " s.")
        return false
    end
    if not W.connected then
        status("This realm doesn't take bug reports in the game. Post it in Discord, #bug-reports.")
        return false
    end
    local kind = B.Kind(win.kind)
    if kind.tag then
        W:SendCommand(B.Line(kind.key, kind.tag .. text, win.context or ""))
    else
        W:SendCommand(B.Line(win.category or "other", text, win.context or ""))
    end
    B.lastSent, B.waiting = GetTime(), GetTime()
    win.send:Disable()
    status("Sending...", true)
    return true
end

-- the realm's answer
W:RegisterModule("BG", function(body)
    B.waiting = nil
    if win then win.send:Enable() end
    local _, _, word, why = string.find(body or "", "^(%a+),?(.*)$")
    if word == "ok" then
        local k = B.Kind(win and win.kind)
        if win then win:Hide() end
        W.Print((k.key == "bug" and "Bug report" or k.label) .. " sent. The team sees it in Discord (#bug-reports). Thank you!")
    elseif why == "ratelimit" then
        status("That's a lot of reports today. Post the rest in Discord, #bug-reports.")
    elseif why == "empty" then
        status("Say what went wrong first.")
    else
        status("This realm doesn't take bug reports in the game. Post it in Discord, #bug-reports.")
    end
end)

local function build()
    if win then return win end
    win = UI.Window("WenillaCore_BugFrame", { width = 330, height = B.HEIGHT, title = "Bugs and feedback", strata = "DIALOG",
        icon = "Interface\\AddOns\\WenillaCore\\Media\\BugButton", point = { "CENTER", UIParent, "CENTER", 0, 60 }, skin = true })
    if UISpecialFrames then table.insert(UISpecialFrames, "WenillaCore_BugFrame") end
    win:Hide()
    local y = -34
    win.tabs = {}
    for i, k in ipairs(B.KINDS) do
        local t = UI.Button(win, k.label, 98, 20, function() B.SetKind(this.key) end)
        t.key = k.key
        t:SetPoint("TOPLEFT", win, "TOPLEFT", 14 + (i - 1) * 102, y)
        win.tabs[i] = t
    end
    y = y - 26
    win.radios = {}
    for i, c in ipairs(B.CATEGORIES) do
        local col = (i - 1) - math.floor((i - 1) / 2) * 2
        local row = math.floor((i - 1) / 2)
        local b = CreateFrame("CheckButton", "WenillaCore_BugCat" .. i, win, "UICheckButtonTemplate")
        b:SetWidth(20); b:SetHeight(20)
        b:SetPoint("TOPLEFT", win, "TOPLEFT", 14 + col * 158, y - row * 20)
        b.key = c.key
        b.label = UI.Label(b, 10, { 0.92, 0.92, 0.95 })
        b.label:SetPoint("LEFT", b, "RIGHT", 4, 0)
        b.label:SetText(c.label)
        b:SetScript("OnClick", function() B.Pick(this.key) end)
        win.radios[i] = b
    end
    y = y - 66
    -- everything below the categories hangs off one anchor, so the Feedback and Idea tabs (no
    -- categories) move it up instead of leaving a gap
    local body = CreateFrame("Frame", nil, win)
    body:SetWidth(1); body:SetHeight(1)
    win.body, win.bodyY = body, y
    body:SetPoint("TOPLEFT", win, "TOPLEFT", 0, y)
    local y0 = y
    local l = UI.Label(win, 10, UI.MUTED)
    l:SetPoint("TOPLEFT", body, "TOPLEFT", 14, y - y0)
    l:SetText(B.KINDS[1].ask)
    win.ask = l
    y = y - 14
    local well = UI.NoteBox(win, "WenillaCore_BugNote", 302, 80, 220)
    well:SetPoint("TOPLEFT", body, "TOPLEFT", 14, y - y0)
    local e = well.edit
    e:SetScript("OnEscapePressed", function() win:Hide() end)
    e:SetScript("OnEnterPressed", function() B.Send() end)          -- Enter sends; the text wraps by itself
    win.hint = UI.Label(well, 10, UI.MUTED)
    win.hint:SetPoint("TOPLEFT", well, "TOPLEFT", 8, -6)
    win.hint:SetText("Click here and type. Enter sends.")
    e:SetScript("OnTextChanged", function()
        local t = e:GetText() or ""
        if t == "" then win.hint:Show() else win.hint:Hide() end
        win.count:SetText(strlen(t) .. " / 220")
    end)
    win.count = UI.Label(win, 9, UI.MUTED)
    win.count:SetPoint("TOPRIGHT", well, "BOTTOMRIGHT", 0, -2)
    win.count:SetText("0 / 220")
    win.note = e
    y = y - 88
    local l2 = UI.Label(win, 10, UI.MUTED)
    l2:SetPoint("TOPLEFT", body, "TOPLEFT", 14, y - y0)
    l2:SetText("Sent with it")
    win.ctx = UI.Label(win, 10, { 0.8, 0.82, 0.86 })
    win.ctx:SetPoint("TOPLEFT", l2, "BOTTOMLEFT", 0, -3)
    win.ctx:SetWidth(302)
    if win.ctx.SetJustifyH then win.ctx:SetJustifyH("LEFT") end
    y = y - 42
    win.status = UI.Label(win, 10, { 1, 0.55, 0.45 })
    win.status:SetPoint("TOPLEFT", body, "TOPLEFT", 14, y - y0)
    win.status:SetWidth(302)
    if win.status.SetJustifyH then win.status:SetJustifyH("LEFT") end
    win.send = UI.Button(win, "Send", 90, 22, function() B.Send() end)
    win.send:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -12, 10)
    win.cancel = UI.Button(win, "Cancel", 80, 22, function() win:Hide() end)
    win.cancel:SetPoint("RIGHT", win.send, "LEFT", -6, 0)
    win:SetScript("OnHide", function() e:ClearFocus() end)
    -- no answer from the realm: say so instead of waiting for ever
    win:SetScript("OnUpdate", function()
        if B.waiting and GetTime() - B.waiting > B.WAIT then
            B.waiting = nil
            win.send:Enable()
            status("No answer from the realm. Post it in Discord, #bug-reports.")
        end
    end)
    return win
end

function B.Open()
    if not (UI and UI.Window) then return false end
    local f = build()
    f.context = B.Context()
    f.ctx:SetText(f.context)
    f.note:SetText("")
    f.send:Enable()
    B.Pick(nil)
    B.SetKind("bug")
    f:Show()
    if f.hint then f.hint:Show() end
    if f.count then f.count:SetText("0 / 220") end
    if f.note.SetFocus then f.note:SetFocus() end
    return true
end

-- the button: right of the chat frame, at its bottom
local function makeButton()
    if button then return button end
    button = CreateFrame("Button", "WenillaCore_BugButton", UIParent)
    button:SetWidth(26); button:SetHeight(26)
    button:SetFrameStrata("MEDIUM")
    local anchor = ChatFrame1
    if anchor then button:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", 8, -6)
    else button:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 420, 100) end
    local t = button:CreateTexture(nil, "ARTWORK")
    t:SetAllPoints(button)
    t:SetTexture("Interface\\AddOns\\WenillaCore\\Media\\BugButton")
    button.icon = t
    local hl = button:CreateTexture(nil, "OVERLAY")       -- shown by hand on hover (see UI.ClassicTabs)
    hl:SetAllPoints(button)
    hl:SetTexture("Interface\\AddOns\\WenillaCore\\Media\\BugButton")
    hl:SetBlendMode("ADD"); hl:SetAlpha(0.35); hl:Hide()
    button.hl = hl
    button:SetScript("OnClick", function() if win and win:IsShown() then win:Hide() else B.Open() end end)
    button:SetScript("OnEnter", function()
        this.hl:Show()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Bug, feedback or idea")
        GameTooltip:AddLine("Tell the team what went wrong, what you think, or what to add. It goes to Discord.", 0.9, 0.9, 0.9, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() this.hl:Hide(); GameTooltip:Hide() end)
    return button
end
makeButton()

SLASH_WNLBUG1 = "/bug"
-- "/bug" opens the window; "/bug <what went wrong>" sends it straight from chat (a first word of
-- quest, spell, addon, graphics, server or other picks the category), for when typing in the box fails.
SlashCmdList["WNLBUG"] = function(msg)
    local text = W.Trim(msg or "")
    if not B.Open() or not win then return end
    if text == "" then return end
    local _, _, first, rest = string.find(text, "^(%a+)%s+(.+)$")
    local cats = { quest = 1, spell = 1, addon = 1, graphics = 1, server = 1, other = 1 }
    if first and cats[string.lower(first)] then B.Pick(string.lower(first)); text = rest end
    win.note:SetText(text)
    if not B.Send() then W.Print("Bug report not sent: " .. (win.status:GetText() or "")) end
end
