--[[
    World.lua  (Chat)
    The realm-wide World channel (world server patch 0007) and the Discord #world bridge (Herald).

        World tab      a tab of its own on the tab bar, on by default: every World line, and the
                       lines from the linked Discord channel marked [D] in Discord blue. Right-click
                       opens its menu (Open, Discord, Join, Hide this tab; the chat tab menu, the Chat
                       settings or /cpchat world bring a hidden tab back);
                       while it is hidden, World and [D] lines show in the main window as [W].
        [W]            World's short name in the other windows (Core.lua's ShortChannel)
        Channel cycle  Tab in an empty input line: Say > Party > Raid > Guild > World (Shift+Tab back)
        /world <text>  say something in World from anywhere (/world alone opens the tab)
        Settings       "World tab", "Show Discord messages", "Join World chat" (.wnl worldoff/worldon)

    Server lines (see realm/mangos/pending/README.md, 0007):
        WD <W|G>,<name>,<text>   a Discord line for World (W) or for your guild's linked channel (G)
        WO <1|0>                 World switched on/off for this character (.wnl worldon / worldoff)
    Your ignore list hides [D] names too. 1.12 has no inline textures (no |T in chat), so the
    per-line mark is the blue [D]; the Chat_Discord art marks the World tab while Discord lines
    are shown. Lua 5.0 rules.
]]--

local W = WenillaCore
local C = CPChat
local strfind, strsub, strlower, strlen, gsub = string.find, string.sub, string.lower, string.len, string.gsub

local function now() return GetTime and GetTime() or 0 end

C.WORLD = "World"
C.WORLD_MAX_LINES = 500
C.DISCORD_HEX = "7289da"
C.DISCORD_MARK = "|cff7289da[D]|r"
C.WORLD_SETTLE = 8          -- seconds after entering the world before "Join World chat" is reconciled
C.world = C.world or { lines = {} }

-- -- State ---------------------------------------------------------------------------------------

function C:WorldId()
    if not GetChannelName then return 0 end
    local id = GetChannelName(self.WORLD)
    return tonumber(id) or 0
end

function C:InWorld() return self:WorldId() > 0 end

function C:IsWorldChannel(name)
    if type(name) ~= "string" then return false end
    name = strlower(name)
    if name == "world" then return true end
    return strfind(name, "^%d+%. world$") and true or false
end

function C:WorldTabShown() return (self.active and self:Get("worldTab")) and true or false end

function C:WorldColour()
    local info = ChatTypeInfo and (ChatTypeInfo["CHANNEL" .. self:WorldId()] or ChatTypeInfo.CHANNEL)
    if info then return info.r or 1, info.g or 0.75, info.b or 0.75 end
    return 1, 0.75, 0.75
end

local function ignored(name)
    if not name or not GetNumIgnores or not GetIgnoreName then return false end
    local low = strlower(name)
    for i = 1, (GetNumIgnores() or 0) do
        local n = GetIgnoreName(i)
        if n and strlower(n) == low then return true end
    end
    return false
end
C.IsIgnored = ignored

-- A Discord name or text from the server, safe to print: no escape sequences.
local function safe(s) return (gsub(s or "", "|", "/")) end

-- -- The World view (a message frame over ChatFrame1, like a whisper tab) --------------------------

function C:WorldFrame()
    if self.worldFrame then return self.worldFrame end
    local f = CreateFrame("ScrollingMessageFrame", "CPChatWorldFrame", UIParent)
    f:SetPoint("TOPLEFT", ChatFrame1, "TOPLEFT", 0, 0)
    f:SetPoint("BOTTOMRIGHT", ChatFrame1, "BOTTOMRIGHT", 0, 0)
    if ChatFrame1.GetFont and f.SetFont then
        local path, size, flags = ChatFrame1:GetFont()
        f:SetFont(path or "Fonts\\ARIALN.TTF", size or 14, flags or "")
    end
    if f.SetJustifyH then f:SetJustifyH("LEFT") end
    if f.SetMaxLines then f:SetMaxLines(self.WORLD_MAX_LINES) end
    if ChatFrame1.GetFrameStrata then f:SetFrameStrata(ChatFrame1:GetFrameStrata() or "LOW") end
    f:EnableMouse(true)
    if f.EnableMouseWheel then f:EnableMouseWheel(true) end
    f:SetScript("OnMouseWheel", C.OnWheel)
    f:SetScript("OnHyperlinkClick", function()
        if ChatFrame_OnHyperlinkShow then ChatFrame_OnHyperlinkShow(arg1, arg2, arg3) else SetItemRef(arg1, arg2, arg3) end
    end)
    f:Hide()
    self.worldFrame = f
    return f
end

function C:RenderWorld()
    local f = self.worldFrame
    if not f then return end
    f:Clear()
    for _, e in ipairs(self.world.lines) do self:Emit(f, e) end
end

function C:ViewWorld()
    if not self:WorldTabShown() then return end
    if self.LeaveWhisper then self:LeaveWhisper() end
    local f = self:WorldFrame()
    if not self.worldView then
        self.hiddenFrame = self:Selected()
        if self.hiddenFrame and self.hiddenFrame ~= f then self.hiddenFrame:Hide() end
    end
    self.worldView = true
    self.world.unread, self.world.mention = nil, nil
    if self.SkinFrame then self:SkinFrame(f) end
    f:Show()
    self:RenderWorld()
    self:RefreshTabs()
end

function C:LeaveWorld()
    if not self.worldView then return end
    self.worldView = nil
    if self.worldFrame then self.worldFrame:Hide() end
    if self.hiddenFrame then self.hiddenFrame:Show() end
    self.hiddenFrame = nil
    self:RefreshTabs()
end

-- One line into the World view's buffer (timestamped like every other line).
function C:AddWorldLine(text, r, g, b, mention)
    local st = self:Stamp()
    if st then text = "|cff" .. self:Theme().stamp .. st .. "|r " .. text end
    local e = { text = text, r = r, g = g, b = b }
    local lines = self.world.lines
    table.insert(lines, e)
    if table.getn(lines) > self.WORLD_MAX_LINES then table.remove(lines, 1) end
    if self.worldView and self.worldFrame then
        self:Emit(self.worldFrame, e)
    else
        self.world.unread = true
        if mention then self.world.mention = true end
        self:StyleWorldTab()
    end
    self:Touch(self:WorldFrame(), mention)
    return e
end

-- -- Lines -----------------------------------------------------------------------------------------

-- A player's line in World (CHAT_MSG_CHANNEL): kept for the World tab.
function C:OnWorldLine(msg, author)
    if not self:WorldTabShown() or type(msg) ~= "string" then return end
    local me = UnitName and UnitName("player")
    local mine = author and author == me
    if not mine and self:Get("goldFilter") and self:IsGoldSpam(msg) then
        self.filtered = self.filtered + 1
        return
    end
    author = author or "?"
    local text = "|Hplayer:" .. author .. "|h[" .. author .. "]|h: " .. msg
    if self:Get("classColors") then text = self:ColourName(text, author) end
    local mention = false
    if not mine and self:MentionsOn(self:WorldFrame()) and self:Mentions(msg) then
        text = self:Highlight(text)
        mention = true
    end
    if self:Get("links") then text = self:Linkify(text) end
    local r, g, b = self:WorldColour()
    return self:AddWorldLine(text, r, g, b, mention)
end

-- WD <W|G>,<name>,<text>: a line from Discord.
function C:OnDiscord(body)
    local _, _, scope, name, text = strfind(body or "", "^(%a),([^,]*),(.*)$")
    if not scope or name == "" then return end
    if not self:Get("discord") or ignored(name) then return end
    name, text = safe(name), safe(text)
    self.discordLines = (self.discordLines or 0) + 1
    if not self.active then                          -- the stock chat: one plain line
        local label = (scope == "G") and "[Guild] " or "[World] "
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(label .. "[D] " .. name .. ": " .. text, self:WorldColour()) end
        return
    end
    local line = self.DISCORD_MARK .. " " .. name .. ": " .. text
    local mention = self:MentionsOn(self:WorldFrame()) and self:Mentions(text)
    if mention then line = self:Highlight(line) end
    if self:Get("links") then line = self:Linkify(line) end
    if scope == "G" then
        local info = ChatTypeInfo and ChatTypeInfo.GUILD
        local label = (self:Get("channelNames") == "full") and "[Guild] " or "[G] "
        DEFAULT_CHAT_FRAME:AddMessage(label .. line, info and info.r or 0.25, info and info.g or 1, info and info.b or 0.25)
        return
    end
    local r, g, b = self:WorldColour()
    if self:WorldTabShown() then
        self:AddWorldLine(line, r, g, b, mention)
    else
        local id = self:WorldId()
        local label = (self:Get("channelNames") == "full") and ("[" .. (id > 0 and (id .. ". ") or "") .. self.WORLD .. "] ") or "[W] "
        DEFAULT_CHAT_FRAME:AddMessage(label .. line, r, g, b)
    end
end

-- WO 1|0: the server's word on this character's World membership.
function C:OnWorldState(body)
    local on = (W.Trim(body or "") == "1")
    self.worldState = on
    local s = W:Settings(self.ID)
    if (s.worldJoin ~= false) ~= on then
        s.worldJoin = on
        if W.Refresh then W:Refresh(self.ID) end
    end
end

-- -- Join World chat: the setting against the channel --------------------------------------------

function C:SyncWorldJoin()
    if not self.worldReady or not W.connected then return end
    if now() - (self.worldAsked or -100) < 5 then return end
    local want = self:Get("worldJoin") and true or false
    local inWorld = self:InWorld()
    if want and not inWorld then
        self.worldAsked = now()
        W:SendCommand("worldon")
    elseif not want and inWorld then
        self.worldAsked = now()
        W:SendCommand("worldoff")
    end
end

-- While the World tab is hidden World lines belong in the main window; a channel the server joined
-- us to is not in ChatFrame1's list, so it is added (and taken out again when the tab comes back).
function C:RouteWorld()
    local s = W:Settings(self.ID)
    local f = DEFAULT_CHAT_FRAME or ChatFrame1
    if not f or not self:InWorld() then return end
    if not self:WorldTabShown() then
        if not s.worldInMain and ChatFrame_AddChannel then
            ChatFrame_AddChannel(f, self.WORLD)
            s.worldInMain = true
        end
    elseif s.worldInMain then
        if ChatFrame_RemoveChannel then ChatFrame_RemoveChannel(f, self.WORLD) end
        s.worldInMain = nil
    end
end

-- -- The tab ---------------------------------------------------------------------------------------

function C:WorldTab()
    local t = CPChatWorldTab
    if t then return t end
    t = CreateFrame("Button", "CPChatWorldTab", self:Bar())
    t:SetHeight(self.TAB_H)
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
    t.mark = t:CreateTexture("CPChatWorldTabDiscord", "OVERLAY")
    t.mark:SetWidth(10)
    t.mark:SetHeight(10)
    t.mark:SetPoint("LEFT", t, "LEFT", 6, 1)
    t.label = t:CreateFontString("CPChatWorldTabText", "OVERLAY", "GameFontHighlightSmall")
    t.label:SetPoint("CENTER", t, "CENTER", 0, 1)
    t.label:SetText(self.WORLD)
    t:SetScript("OnClick", function()
        if arg1 == "RightButton" then
            if GameTooltip then GameTooltip:Hide() end
            C:WorldTabMenu(t)          -- a menu, like the stock chat tabs; hiding the tab is one choice in it
            return
        end
        C:ViewWorld()
    end)
    t:SetScript("OnEnter", function()
        C.lastActivity = now()
        if GameTooltip then
            GameTooltip:SetOwner(t, "ANCHOR_TOP")
            GameTooltip:SetText("World", 1, 1, 1)
            GameTooltip:AddLine("Realm-wide chat, both factions. Type /world <text>.", 0.85, 0.85, 0.85)
            if C:Get("discord") then GameTooltip:AddLine("Linked to the realm's Discord: [D] lines come from there.", 0.45, 0.54, 0.85) end
            if not C:InWorld() then GameTooltip:AddLine("You are not in World chat (Chat settings: Join World chat).", 1, 0.5, 0.3) end
            GameTooltip:AddLine("Right-click for options", 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end
    end)
    t:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    t:Hide()
    return t
end

-- Look and width of the World tab; Skin.lua's tab strip places it (C:LayoutTabs).
function C:LayoutWorldTab() self:LayoutTabs() end

function C:PrepWorldTab()
    local t = CPChatWorldTab
    if not self:WorldTabShown() then
        if t then t:Hide() end
        return
    end
    t = self:WorldTab()
    local discord = self:Get("discord") and true or false
    if discord then
        if not W:Art(t.mark, "Chat_Discord", nil) then t.mark:SetTexture(0.447, 0.537, 0.855, 1) end
        t.mark:Show()
    else
        t.mark:Hide()
    end
    if t.label.SetFont then t.label:SetFont("Fonts\\FRIZQT__.TTF", 10, self:Theme().flags) end
    if t.label.SetWidth then t.label:SetWidth(0) end
    t.label:ClearAllPoints()
    local tw = t.label:GetStringWidth() or 30
    if tw < 24 then tw = 30 end
    local w
    if discord then
        -- the mark, then the label right after it: never centred over the mark
        t.label:SetPoint("LEFT", t.mark, "RIGHT", 5, 0)
        w = 6 + 10 + 5 + tw + 12
    else
        t.label:SetPoint("CENTER", t, "CENTER", 0, 1)
        w = tw + 20
    end
    if w < 44 then w = 44 end
    t.cpWant = w
    t:SetWidth(w)
    t:Show()
    self:StyleWorldTab()
end

function C:StyleWorldTab(theme)
    local t = CPChatWorldTab
    if not t or not t:IsShown() or not self.active then return end
    t.cpUnread = self.world.unread
    t.cpMention = self.world.mention
    self:StyleTab(t, self.worldView and true or false, theme or self:Theme())
end

-- -- The channel cycle (Tab in an empty input line) ---------------------------------------------

function C:ChannelCycle()
    local list = { { "SAY" } }
    if GetNumPartyMembers and (GetNumPartyMembers() or 0) > 0 then table.insert(list, { "PARTY" }) end
    if GetNumRaidMembers and (GetNumRaidMembers() or 0) > 0 then table.insert(list, { "RAID" }) end
    if IsInGuild and IsInGuild() then table.insert(list, { "GUILD" }) end
    local id = self:WorldId()
    if id > 0 then table.insert(list, { "CHANNEL", id }) end
    return list
end

function C:CycleChannel(eb, back)
    if not eb then return false end
    local text = eb.GetText and eb:GetText() or ""
    if text and not strfind(text, "^%s*$") then return false end
    local t = eb.chatType or "SAY"
    if t == "WHISPER" then return false end          -- the stock Tab steps through tell targets
    local list = self:ChannelCycle()
    local n = table.getn(list)
    local cur = 0
    for i, c in ipairs(list) do
        if c[1] == t and (t ~= "CHANNEL" or tostring(c[2]) == tostring(eb.channelTarget)) then cur = i end
    end
    local nxt
    if back then nxt = cur - 1 else nxt = cur + 1 end
    if nxt < 1 then nxt = n elseif nxt > n then nxt = 1 end
    local pick = list[nxt]
    eb.chatType = pick[1]
    if pick[1] == "CHANNEL" then eb.channelTarget = pick[2] end
    if ChatEdit_UpdateHeader then ChatEdit_UpdateHeader(eb) end
    return true
end

local eb = ChatFrameEditBox
if eb and eb.GetScript then
    local origTab = eb:GetScript("OnTabPressed")
    eb:SetScript("OnTabPressed", function()
        if C.active and C:CycleChannel(this or ChatFrameEditBox, IsShiftKeyDown and IsShiftKeyDown()) then return end
        if origTab then origTab() end
    end)
end

-- Enter while the World tab is open: you are writing to World.
local openHooked = false
local function hookOpenChat()
    if openHooked or type(ChatFrame_OpenChat) ~= "function" then return end
    openHooked = true
    local orig = ChatFrame_OpenChat
    ChatFrame_OpenChat = function(text, chatFrame)
        local r = orig(text, chatFrame)
        if C.active and C.worldView and (text == nil or text == "") and ChatFrameEditBox and C:InWorld() then
            ChatFrameEditBox.chatType = "CHANNEL"
            ChatFrameEditBox.channelTarget = C:WorldId()
            if ChatEdit_UpdateHeader then ChatEdit_UpdateHeader(ChatFrameEditBox) end
        end
        return r
    end
end

-- -- /world ----------------------------------------------------------------------------------------

SLASH_CPWORLD1 = "/world"
SlashCmdList["CPWORLD"] = function(msg)
    msg = W.Trim(msg or "")
    local id = C:WorldId()
    if id == 0 then
        if C:Get("worldJoin") then
            W.Print("You are not in World chat yet. It joins a few seconds after you log in (or type .wnl worldon).")
        else
            W.Print("World chat is off. Turn on \"Join World chat\" in the Chat settings to talk there.")
        end
        return
    end
    if msg == "" then
        if C:WorldTabShown() then C:ViewWorld() end
        if ChatFrame_OpenChat then ChatFrame_OpenChat("/" .. id .. " ") end
        return
    end
    if strlen(msg) > 255 then msg = strsub(msg, 1, 255) end
    SendChatMessage(msg, "CHANNEL", nil, id)
end

-- The World tab's right-click menu: open it, the Discord and join switches, hide the tab (asked, never
-- by accident: a stray right-click used to make the tab vanish), all settings.
function C:WorldTabMenu(anchor)
    local UI = W.UI
    if not UI or not UI.Menu then return end
    local items = {
        { text = "World chat", title = true },
        { text = "Open World chat", func = function() C:ViewWorld() end },
        { text = "Show Discord messages", checked = self:Get("discord") and true or false, func = function() C:SetOption("discord", not C:Get("discord")) end },
        { text = "Join World chat", checked = self:Get("worldJoin") and true or false, func = function() C:SetOption("worldJoin", not C:Get("worldJoin")) end },
        { text = "Hide this tab", func = function()
            C:SetOption("worldTab", false)
            W.Print("World tab hidden; World chat shows in the main window as [W]. Open the chat menu (the ... button on the chat bar) and tick \"Show the World tab\", or type /cpchat world, to bring it back.")
        end },
        { text = "All chat settings...", func = function() C:OpenSettings() end },
    }
    self.menu = UI.Menu(anchor, items)
    if self.menu then
        self.menu:ClearAllPoints()
        self.menu:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
    end
    return self.menu
end

-- Tabs hidden by a stray right-click before the menu existed come back once (chat 1.2).
function C:RestoreTabsOnce()
    local s = W:Settings(self.ID)
    if s.tabsRestored then return end
    s.tabsRestored = true
    if s.worldTab == false then s.worldTab = true end
    local g = W:Settings("Guilds")
    if g and g.showChatTab == false then g.showChatTab = true; if W.Refresh then W:Refresh("Guilds") end end
end

-- -- Apply -----------------------------------------------------------------------------------------

function C:ApplyWorld()
    hookOpenChat()
    if not self:WorldTabShown() then
        self:LeaveWorld()
        if CPChatWorldTab then CPChatWorldTab:Hide() end
    else
        self:LayoutWorldTab()
        if self.worldView and self.worldFrame and self.SkinFrame then self:SkinFrame(self.worldFrame) end
    end
    if self.worldFrame and not self.active and self.UnskinFrame then self:UnskinFrame(self.worldFrame) end
    if self.active then self:RouteWorld() end
    self:SyncWorldJoin()
end

W:RegisterModule("WD", function(body) C:OnDiscord(body) end)
W:RegisterModule("WO", function(body) C:OnWorldState(body) end)

local ev = CreateFrame("Frame", "CPChatWorldEvents")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_CHANNEL")
ev:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
ev:SetScript("OnEvent", function()
    if event == "CHAT_MSG_CHANNEL" then
        if C:IsWorldChannel(arg9) or (not arg9 and C:IsWorldChannel(arg4)) then C:OnWorldLine(arg1, arg2) end
    elseif event == "CHAT_MSG_CHANNEL_NOTICE" then
        if C:IsWorldChannel(arg9) or (not arg9 and C:IsWorldChannel(arg4)) then
            if arg1 == "YOU_JOINED" or arg1 == "YOU_LEFT" then
                if C.active then C:RouteWorld(); C:LayoutWorldTab() end
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not C.tabsChecked then C.tabsChecked = true; C:RestoreTabsOnce(); if C.active and C.ApplyWorld then C:ApplyWorld() end end
        if not C.worldReady and not C.worldSettleAt then C.worldSettleAt = now() + C.WORLD_SETTLE end
    end
end)
ev:SetScript("OnUpdate", function()
    if C.worldSettleAt and now() >= C.worldSettleAt then
        C.worldSettleAt = nil
        C.worldReady = true
        if C.active then C:RouteWorld() end
        C:SyncWorldJoin()
    end
end)
