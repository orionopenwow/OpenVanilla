--[[
    Tools.lua  (Chat)
        Copy chat      the last 200 lines of a tab in a selectable box (tab bar button, /cpchat copy)
        Link box       clicking a web link in chat opens it, highlighted, ready for Ctrl+C
        Whisper tabs   optional: each whisper conversation in its own tab on the tab bar
        Typed history  lines you sent come back with the up/down arrows, even after a reload
]]--

local W = WenillaCore
local C = CPChat
local strsub, strlen, strfind = string.sub, string.len, string.find

local function now() return GetTime and GetTime() or 0 end

C.COPY_LINES = 200

-- -- Copy chat ---------------------------------------------------------------------------------

function C:CopyWindow()
    if self.copyWin then return self.copyWin end
    local UI = W.UI
    local f = UI.Window("CPChatCopy", { width = 560, height = 380, title = "Copy chat", icon = "Interface\\Icons\\INV_Scroll_03", strata = "DIALOG", skin = true })
    if UISpecialFrames then table.insert(UISpecialFrames, "CPChatCopy") end
    local hint = UI.Label(f, 10, UI.MUTED)
    hint:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    hint:SetText("The last 200 lines. Select what you need and press Ctrl+C.")
    f.hint = hint

    local well = CreateFrame("Frame", nil, f)
    UI.Skin(well, "inset")
    well:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -48)
    well:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 40)

    local sf = CreateFrame("ScrollFrame", "CPChatCopyScroll", well, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", well, "TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -26, 6)
    local box = CreateFrame("EditBox", "CPChatCopyBox", sf)
    box:SetMultiLine(true)
    box:SetMaxLetters(0)
    box:SetAutoFocus(false)
    box:SetWidth(500)
    box:SetHeight(280)
    box:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    box:SetScript("OnEscapePressed", function() f:Hide() end)
    box:SetScript("OnTextChanged", function()
        if ScrollingEdit_OnTextChanged then ScrollingEdit_OnTextChanged(sf) end
        -- read-only: typing puts the text back
        if f.text and box:GetText() ~= f.text and not f.setting then
            f.setting = true
            box:SetText(f.text)
            f.setting = nil
        end
    end)
    box:SetScript("OnCursorChanged", function()
        if ScrollingEdit_OnCursorChanged then ScrollingEdit_OnCursorChanged(arg1, arg2, arg3, arg4) end
    end)
    box:SetScript("OnUpdate", function()
        if ScrollingEdit_OnUpdate then ScrollingEdit_OnUpdate(sf) end
        if f.toBottom then
            f.toBottom = f.toBottom - 1
            if sf.UpdateScrollChildRect then sf:UpdateScrollChildRect() end
            if sf.GetVerticalScrollRange then sf:SetVerticalScroll(sf:GetVerticalScrollRange() or 0) end
            if f.toBottom <= 0 then f.toBottom = nil end
        end
    end)
    sf:SetScrollChild(box)
    f.box, f.scroll = box, sf

    local all = UI.Button(f, "Select all", 110, 22, function()
        box:SetFocus()
        box:HighlightText()
    end)
    all:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 10)
    local close = UI.Button(f, "Close", 80, 22, function() f:Hide() end)
    close:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
    f.count = UI.Label(f, 10, UI.MUTED)
    f.count:SetPoint("LEFT", all, "RIGHT", 10, 0)
    f:Hide()
    self.copyWin = f
    return f
end

-- Plain text of the last n lines of a chat tab (or the open whisper conversation).
function C:CopyText(frame, n)
    n = n or self.COPY_LINES
    local lines
    if not frame and self.worldView and self.world then
        lines = self.world.lines
    elseif not frame and self.whisperView then
        local cv = self:Convo(self.whisperView)
        lines = cv and cv.lines
    else
        frame = frame or self:Selected() or ChatFrame1
        lines = frame and frame.cpLines
    end
    lines = lines or {}
    local total = table.getn(lines)
    local out = {}
    for i = math.max(1, total - n + 1), total do
        table.insert(out, C.Strip(lines[i].text))
    end
    return table.concat(out, "\n"), table.getn(out)
end

function C:OpenCopy(frame)
    local f = self:CopyWindow()
    local text, count = self:CopyText(frame)
    f.text = text
    f.setting = true
    f.box:SetText(text)
    f.setting = nil
    f.count:SetText(count == 1 and "1 line" or (count .. " lines"))
    f.toBottom = 3
    f:Show()
    f.box:SetFocus()
    f.box:HighlightText()
    return f
end

-- -- Link box ----------------------------------------------------------------------------------

function C:LinkWindow()
    if self.linkWin then return self.linkWin end
    local UI = W.UI
    local f = UI.Window("CPChatLink", { width = 400, height = 96, title = "Copy link", icon = "Interface\\Icons\\INV_Scroll_03", strata = "DIALOG", skin = true })
    if UISpecialFrames then table.insert(UISpecialFrames, "CPChatLink") end
    local e = CreateFrame("EditBox", "CPChatLinkBox", f)
    UI.Skin(e, "inset")
    e:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -34)
    e:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -34)
    e:SetHeight(22)
    e:SetAutoFocus(false)
    e:SetMaxLetters(0)
    e:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    if e.SetTextInsets then e:SetTextInsets(6, 6, 0, 0) end
    e:SetTextColor(0.55, 0.78, 1)
    e:SetScript("OnEscapePressed", function() f:Hide() end)
    e:SetScript("OnEnterPressed", function() f:Hide() end)
    e:SetScript("OnTextChanged", function()
        if f.url and e:GetText() ~= f.url and not f.setting then
            f.setting = true
            e:SetText(f.url)
            e:HighlightText()
            f.setting = nil
        end
    end)
    local hint = UI.Label(f, 10, UI.MUTED)
    hint:SetPoint("TOPLEFT", e, "BOTTOMLEFT", 2, -8)
    hint:SetText("Press Ctrl+C to copy it, then Escape. Links open outside the game.")
    f.box = e
    f:Hide()
    self.linkWin = f
    return f
end

function C:OpenLink(url)
    local f = self:LinkWindow()
    f.url = url
    f.setting = true
    f.box:SetText(url)
    f.setting = nil
    f:Show()
    f.box:SetFocus()
    f.box:HighlightText()
    return f
end

local origSetItemRef = SetItemRef
function SetItemRef(link, text, button)
    if type(link) == "string" and strsub(link, 1, 4) == "url:" then
        C:OpenLink(strsub(link, 5))
        return
    end
    if origSetItemRef then return origSetItemRef(link, text, button) end
end

-- -- Typed history ---------------------------------------------------------------------------------
-- The stock edit box keeps what you send for the up/down arrows, but forgets it on a reload.
-- Lines added to its history are also saved per character and put back at login.

C.MAX_HISTORY = 50

local function history()
    if type(ClassicPlus_ChatHistory) ~= "table" then ClassicPlus_ChatHistory = {} end
    if type(ClassicPlus_ChatHistory.lines) ~= "table" then ClassicPlus_ChatHistory.lines = {} end
    return ClassicPlus_ChatHistory.lines
end
C.History = history

function C:Remember(line)
    if not self.active or not self:Get("typedHistory") then return end
    if type(line) ~= "string" or line == "" or strfind(line, "^%s*$") then return end
    local h = history()
    if h[table.getn(h)] == line then return end
    table.insert(h, line)
    while table.getn(h) > self.MAX_HISTORY do table.remove(h, 1) end
end

local eb = ChatFrameEditBox
if eb then
    local origAdd = eb.AddHistoryLine
    C.AddHistoryLineStock = origAdd
    eb.AddHistoryLine = function(self, line)
        C.sawHistory = true
        C:Remember(line)
        if origAdd then return origAdd(self, line) end
    end
    local origEnter = eb:GetScript("OnEnterPressed")
    eb:SetScript("OnEnterPressed", function()
        local text = this:GetText()
        C.sawHistory = nil
        if origEnter then origEnter() end
        if not C.sawHistory and text and text ~= "" then C:Remember(text) end
        C.sawHistory = nil
    end)
end

function C:RestoreHistory()
    if self.historyLoaded or not ChatFrameEditBox or not self:Get("typedHistory") then return end
    self.historyLoaded = 0
    local add = self.AddHistoryLineStock
    for _, line in ipairs(history()) do
        if add then add(ChatFrameEditBox, line) end
        self.historyLoaded = self.historyLoaded + 1
    end
end

-- -- Whisper tabs ----------------------------------------------------------------------------------

C.convos = {}
C.MAX_CONVOS = 6
C.MAX_CONVO_LINES = 300

function C:Convo(name, create)
    for _, cv in ipairs(self.convos) do
        if cv.name == name then return cv end
    end
    if not create then return nil end
    -- room for a new one: drop the oldest conversation you are not reading
    if table.getn(self.convos) >= self.MAX_CONVOS then
        for i, cv in ipairs(self.convos) do
            if cv.name ~= self.whisperView then table.remove(self.convos, i) break end
        end
    end
    local cv = { name = name, lines = {} }
    table.insert(self.convos, cv)
    return cv
end

function C:WhisperFrame()
    if self.whisperFrame then return self.whisperFrame end
    local f = CreateFrame("ScrollingMessageFrame", "CPChatWhisperFrame", UIParent)
    f:SetPoint("TOPLEFT", ChatFrame1, "TOPLEFT", 0, 0)
    f:SetPoint("BOTTOMRIGHT", ChatFrame1, "BOTTOMRIGHT", 0, 0)
    if ChatFrame1.GetFont and f.SetFont then
        local path, size, flags = ChatFrame1:GetFont()
        f:SetFont(path or "Fonts\\ARIALN.TTF", size or 14, flags or "")
    end
    if f.SetJustifyH then f:SetJustifyH("LEFT") end
    if f.SetMaxLines then f:SetMaxLines(self.MAX_CONVO_LINES) end
    if ChatFrame1.GetFrameStrata then f:SetFrameStrata(ChatFrame1:GetFrameStrata() or "LOW") end
    f:EnableMouse(true)
    if f.EnableMouseWheel then f:EnableMouseWheel(true) end
    f:SetScript("OnMouseWheel", C.OnWheel)
    f:SetScript("OnHyperlinkClick", function()
        if ChatFrame_OnHyperlinkShow then ChatFrame_OnHyperlinkShow(arg1, arg2, arg3) else SetItemRef(arg1, arg2, arg3) end
    end)
    f:Hide()
    self.whisperFrame = f
    return f
end

function C:RouteWhisper(name, text, r, g, b, ev, raw)
    if not name or name == "" then return end
    local key = (ev or "") .. "\1" .. name .. "\1" .. (raw or text) .. "\1" .. now()
    if key == self.lastRoute then return end      -- several chat frames print the same whisper
    self.lastRoute = key
    local cv = self:Convo(name, true)
    local e = { text = text, r = r, g = g, b = b }
    table.insert(cv.lines, e)
    if table.getn(cv.lines) > self.MAX_CONVO_LINES then table.remove(cv.lines, 1) end
    self.lastActivity = now()
    if self.whisperView == name then
        self:Emit(self:WhisperFrame(), e)
    else
        cv.unread = true
    end
    self:LayoutWhisperTabs()
    self:StyleWhisperTabs()
end

function C:RenderWhispers()
    local f = self.whisperFrame
    if not f then return end
    f:Clear()
    local cv = self.whisperView and self:Convo(self.whisperView)
    if not cv then return end
    for _, e in ipairs(cv.lines) do self:Emit(f, e) end
end

function C:ViewWhisper(name)
    local cv = self:Convo(name)
    if not cv then return end
    if self.LeaveWorld then self:LeaveWorld() end
    local f = self:WhisperFrame()
    if not self.whisperView then
        self.hiddenFrame = self:Selected()
        if self.hiddenFrame and self.hiddenFrame ~= f then self.hiddenFrame:Hide() end
    end
    self.whisperView = name
    cv.unread = nil
    self:SkinFrame(f)
    f:Show()
    self:RenderWhispers()
    self:RefreshTabs()
end

function C:LeaveWhisper()
    if not self.whisperView then return end
    self.whisperView = nil
    if self.whisperFrame then self.whisperFrame:Hide() end
    if self.hiddenFrame then self.hiddenFrame:Show() end
    self.hiddenFrame = nil
    self:RefreshTabs()
end

function C:CloseWhisper(name)
    for i, cv in ipairs(self.convos) do
        if cv.name == name then table.remove(self.convos, i) break end
    end
    if self.whisperView == name then self:LeaveWhisper() end
    self:LayoutWhisperTabs()
    self:StyleWhisperTabs()
end

local function whisperTab(i)
    local bar = C:Bar()
    local t = getglobal("CPChatWhisperTab" .. i)
    if t then return t end
    t = CreateFrame("Button", "CPChatWhisperTab" .. i, bar)
    t:SetHeight(C.TAB_H)
    t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    t.cpBg = t:CreateTexture(nil, "BACKGROUND")
    t.cpBg:SetAllPoints(t)
    t.cpLine = t:CreateTexture(nil, "ARTWORK")
    t.cpLine:SetHeight(2)
    t.cpLine:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 3, 0)
    t.cpLine:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -3, 0)
    t.cpDot = t:CreateTexture(nil, "OVERLAY")
    t.cpDot:SetWidth(6)
    t.cpDot:SetHeight(6)
    t.cpDot:SetPoint("TOPRIGHT", t, "TOPRIGHT", -3, -3)
    t.label = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t.label:SetPoint("CENTER", t, "CENTER", 0, 1)
    t:SetScript("OnClick", function()
        if not t.convo then return end
        if arg1 == "RightButton" then C:CloseWhisper(t.convo) else C:ViewWhisper(t.convo) end
    end)
    t:SetScript("OnEnter", function()
        C.lastActivity = now()
        if GameTooltip and t.convo then
            GameTooltip:SetOwner(t, "ANCHOR_TOP")
            GameTooltip:SetText("Whispers with " .. t.convo, 1, 1, 1)
            GameTooltip:AddLine("Right-click to close this tab", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end
    end)
    t:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return t
end

-- Labels, widths and which whisper tabs show; Skin.lua's tab strip places them (C:LayoutTabs).
function C:LayoutWhisperTabs() self:LayoutTabs() end

function C:PrepWhisperTabs()
    local on = self.active and self:Get("whisperTabs")
    local n = on and table.getn(self.convos) or 0
    for i = 1, self.MAX_CONVOS do
        local t = (i <= n) and whisperTab(i) or getglobal("CPChatWhisperTab" .. i)
        if t then
            if i <= n then
                local cv = self.convos[n - i + 1]          -- newest nearest the buttons
                t.convo = cv.name
                t.label:SetText(cv.name)
                if t.label.SetFont then t.label:SetFont("Fonts\\FRIZQT__.TTF", 10, self:Theme().flags) end
                if t.label.SetWidth then t.label:SetWidth(0) end
                local w = (t.label:GetStringWidth() or 30) + 20
                if w < 40 then w = 40 elseif w > 96 then w = 96 end
                t.cpWant = w
                t:SetWidth(w)
                t:Show()
            else
                t.convo = nil
                t:Hide()
            end
        end
    end
end

function C:StyleWhisperTabs(theme)
    theme = theme or self:Theme()
    for i = 1, self.MAX_CONVOS do
        local t = getglobal("CPChatWhisperTab" .. i)
        if t and t:IsShown() and t.convo then
            local cv = self:Convo(t.convo)
            t.cpUnread = cv and cv.unread
            t.cpMention = nil
            self:StyleTab(t, self.whisperView == t.convo, theme)
            if not t.cpUnread then t.cpDot:SetAlpha(0) end
        end
    end
end

function C:SetWhisperChrome(a)
    -- whisper tabs sit on the bar, which fades with the panels
end

-- -- Apply -----------------------------------------------------------------------------------------

local hooked = false
local function hookOpenChat()
    if hooked or type(ChatFrame_OpenChat) ~= "function" then return end
    hooked = true
    local orig = ChatFrame_OpenChat
    ChatFrame_OpenChat = function(text, chatFrame)
        local r = orig(text, chatFrame)
        -- Enter while a whisper tab is open: you are writing to that person
        if C.active and C.whisperView and (text == nil or text == "") and ChatFrameEditBox then
            ChatFrameEditBox.chatType = "WHISPER"
            ChatFrameEditBox.tellTarget = C.whisperView
            if ChatEdit_UpdateHeader then ChatEdit_UpdateHeader(ChatFrameEditBox) end
        end
        return r
    end
end

function C:ApplyTools()
    hookOpenChat()
    if self.active then self:RestoreHistory() end
    if not self.active or not self:Get("whisperTabs") then
        self:LeaveWhisper()
    elseif self.whisperView and self.whisperFrame then
        self:SkinFrame(self.whisperFrame)
    end
    if self.whisperFrame and not self.active then self:UnskinFrame(self.whisperFrame) end
    self:LayoutWhisperTabs()
    if self.active then self:StyleWhisperTabs() end
end
