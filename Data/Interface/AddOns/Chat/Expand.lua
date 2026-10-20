--[[
    Expand.lua  (Chat)
    The expanded chat window: the whole history of the tab you are on (General, Combat Log, World,
    a whisper) in a large window you can maximize, with a search box that filters the lines, the
    newest line kept in view, links you can click, and new lines arriving live.

        Open           the expand button on the tab bar (left of Copy), the chat menu, or /cpchat expand
        Maximize       the button top right toggles between a large window and nearly the whole screen
        Search         case-insensitive, colour codes ignored; Escape clears it, Escape again closes
        Mouse wheel    scrolls; Shift+wheel jumps to the top or the newest line
        Newest         back to the newest line;  Copy opens the copy window on the same tab

    Lines come from the same buffers the chat keeps (frame.cpLines, up to C.MAX_BUFFER; the World
    tab's own buffer; a whisper conversation), in their own colours (the parchment theme's ink is
    for the parchment, so it is not used on this dark window). Lua 5.0 rules: no '#', no '%'.
]]--

local W = WenillaCore
local C = CPChat
local strlower, strfind = string.lower, string.find

C.EXPAND_LINES = 1200          -- more than any buffer keeps (C.MAX_BUFFER is 1000)
C.EXPAND_SIZE = 0.7            -- share of the screen, normal
C.EXPAND_MAX_SIZE = 0.94       -- share of the screen, maximized
C.EXPAND_POLL = 0.4            -- seconds between checks for new lines

local function now() return GetTime and GetTime() or 0 end

local function tabName(f)
    local t = f and f.GetName and getglobal(f:GetName() .. "TabText")
    local n = t and t.GetText and t:GetText()
    if n and n ~= "" then return n end
    return "Chat"
end

-- the lines of the tab you are on, and its name
function C:ExpandSource()
    if self.worldView and self.world then return self.world.lines, self.WORLD or "World", nil end
    if self.whisperView and self.Convo then
        local cv = self:Convo(self.whisperView)
        return (cv and cv.lines) or {}, "Whisper: " .. tostring(self.whisperView), nil
    end
    local f = self:Selected() or ChatFrame1
    return (f and f.cpLines) or {}, tabName(f), f
end

local function size(win, share)
    local sw = (UIParent and UIParent:GetWidth()) or 1024
    local sh = (UIParent and UIParent:GetHeight()) or 768
    local w, h = math.floor(sw * share), math.floor(sh * share)
    if w < 620 then w = 620 end
    if h < 400 then h = 400 end
    win:SetWidth(w)
    win:SetHeight(h)
    win:ClearAllPoints()
    win:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

function C:ExpandWindow()
    if self.expandWin then return self.expandWin end
    local UI = W.UI
    local f = UI.Window("CPChatExpanded", { width = 760, height = 500, title = "Chat history", icon = "Interface\\Icons\\INV_Scroll_03", strata = "DIALOG", skin = true })
    if UISpecialFrames then table.insert(UISpecialFrames, "CPChatExpanded") end
    f:Hide()

    f.head = UI.Label(f, 11, UI.ACCENT)
    f.head:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -34)
    f.count = UI.Label(f, 10, UI.MUTED)
    f.count:SetPoint("LEFT", f.head, "RIGHT", 10, 0)

    f.max = UI.Button(f, "Maximize", 90, 20, function() C:ToggleExpandSize() end)
    f.max:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -30)
    f.search = UI.SearchBox(f, { name = "CPChatExpandedSearch", width = 200, placeholder = "Search this tab",
        onChange = function() if f:IsShown() then C:FillExpanded() end end })
    f.search:SetPoint("RIGHT", f.max, "LEFT", -8, 0)
    f.search:SetScript("OnEscapePressed", function()
        if (f.search:GetText() or "") ~= "" then f.search:SetText("") else f:Hide() end
    end)

    local well = CreateFrame("Frame", nil, f)
    UI.Skin(well, "inset")
    well:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -56)
    well:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 40)
    f.well = well

    local m = CreateFrame("ScrollingMessageFrame", "CPChatExpandedLines", well)
    m:SetPoint("TOPLEFT", well, "TOPLEFT", 8, -6)
    m:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -8, 6)
    m:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    if m.SetJustifyH then m:SetJustifyH("LEFT") end
    if m.SetFading then m:SetFading(false) end
    if m.SetMaxLines then m:SetMaxLines(C.EXPAND_LINES) end
    m:EnableMouse(true)
    if m.EnableMouseWheel then m:EnableMouseWheel(true) end
    m:SetScript("OnMouseWheel", function()
        local up = (arg1 or 0) > 0
        if IsShiftKeyDown and IsShiftKeyDown() then
            if up then m:ScrollToTop() else m:ScrollToBottom() end
        elseif up then m:ScrollUp(); m:ScrollUp(); m:ScrollUp()
        else m:ScrollDown(); m:ScrollDown(); m:ScrollDown() end
    end)
    m:SetScript("OnHyperlinkClick", function()
        if ChatFrame_OnHyperlinkShow then ChatFrame_OnHyperlinkShow(arg1, arg2, arg3) elseif SetItemRef then SetItemRef(arg1, arg2, arg3) end
    end)
    f.lines = m

    f.empty = UI.Label(well, 11, UI.MUTED)
    f.empty:SetPoint("CENTER", well, "CENTER", 0, 0)

    f.newest = UI.Button(f, "Newest", 90, 22, function() m:ScrollToBottom() end)
    f.newest:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 10)
    f.copy = UI.Button(f, "Copy", 80, 22, function() C:OpenCopy(f.frame) end)
    f.copy:SetPoint("LEFT", f.newest, "RIGHT", 6, 0)
    f.close = UI.Button(f, "Close", 80, 22, function() f:Hide() end)
    f.close:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
    f.hint = UI.Label(f, 9, UI.MUTED)
    f.hint:SetPoint("LEFT", f.copy, "RIGHT", 12, 0)
    f.hint:SetText("Mouse wheel scrolls; Shift+wheel jumps to the top or the newest line.")

    -- new lines arrive while it is open
    f.since = 0
    f:SetScript("OnUpdate", function()
        f.since = f.since + (arg1 or 0)
        if f.since < C.EXPAND_POLL then return end
        f.since = 0
        local lines = C:ExpandSource()
        local n = table.getn(lines)
        if lines ~= f.source or n ~= f.seenN or lines[n] ~= f.seenLast then C:FillExpanded() end
    end)
    f:SetScript("OnHide", function() if f.search.ClearFocus then f.search:ClearFocus() end end)
    size(f, C.EXPAND_SIZE)
    self.expandWin = f
    return f
end

-- (re)print the lines of the current tab that match the search
function C:FillExpanded()
    local f = self.expandWin
    if not f then return end
    local lines, name, frame = self:ExpandSource()
    local n = table.getn(lines)
    local q = strlower(W.Trim(f.search:GetText() or ""))
    local m = f.lines
    m:Clear()
    local shown = 0
    for i = 1, n do
        local e = lines[i]
        if e and e.text and (q == "" or strfind(strlower(C.Strip(e.text) or ""), q, 1, true)) then
            m:AddMessage(e.text, e.r or 1, e.g or 1, e.b or 1)
            shown = shown + 1
        end
    end
    m:ScrollToBottom()
    f.source, f.seenN, f.seenLast, f.frame = lines, n, lines[n], frame
    f.head:SetText(name)
    if q == "" then f.count:SetText(n .. (n == 1 and " line" or " lines"))
    else f.count:SetText(shown .. " of " .. n .. " lines match") end
    if shown == 0 then
        f.empty:SetText(n == 0 and "Nothing here yet." or "No line matches your search.")
        f.empty:Show()
    else
        f.empty:Hide()
    end
    self.expandShown = shown
end

function C:ToggleExpandSize()
    local f = self:ExpandWindow()
    f.maximized = not f.maximized
    size(f, f.maximized and C.EXPAND_MAX_SIZE or C.EXPAND_SIZE)
    f.max:SetText(f.maximized and "Restore" or "Maximize")
end

function C:OpenExpanded()
    local f = self:ExpandWindow()
    if f:IsShown() then f:Hide() return f end
    f.search:SetText("")
    self:FillExpanded()
    f:Show()
    return f
end
