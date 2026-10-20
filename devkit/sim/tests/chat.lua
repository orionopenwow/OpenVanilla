-- Chat: the restyled chat window (themes, opacity, tabs, input line) and its tools (timestamps,
-- short channel names, class colours, links, copy box, spam control, history, mentions, whisper
-- tabs), and that turning it off gives back the stock chat exactly.
local T, api = ...

-- A client with the stock chat pieces the skin restyles (the fake client has the frames but not
-- their textures and buttons), then Chat loaded and logged in.
local function stockPieces(env)
    local cf = env.ChatFrame1
    env.CreateFrame("Button", "ChatFrameMenuButton", env.UIParent)
    for i = 1, 2 do
        local f = env["ChatFrame" .. i]
        for _, b in ipairs({ "UpButton", "DownButton", "BottomButton" }) do
            env.CreateFrame("Button", "ChatFrame" .. i .. b, f)
        end
        f:CreateTexture("ChatFrame" .. i .. "Background", "BACKGROUND"):SetTexture(0, 0, 0, 0.25)
        local tab = env["ChatFrame" .. i .. "Tab"]
        for _, n in ipairs({ "Left", "Middle", "Right", "Flash" }) do tab:CreateTexture("ChatFrame" .. i .. "Tab" .. n, "BACKGROUND") end
        tab:CreateFontString("ChatFrame" .. i .. "TabText", "OVERLAY"):SetText(i == 1 and "General" or "Combat Log")
        tab:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 2 + (i - 1) * 70, -4)
        tab:SetHeight(32)
        tab:SetWidth(64)
    end
    cf.isDocked, env.ChatFrame2.isDocked = 1, 1
    env.DOCKED_CHAT_FRAMES = { cf, env.ChatFrame2 }
    env.SELECTED_DOCK_FRAME = cf
    local eb = env.ChatFrameEditBox
    eb:SetPoint("TOPLEFT", cf, "BOTTOMLEFT", -5, -2)
    eb:SetHeight(32)
    for _, n in ipairs({ "Left", "Right", "Mid" }) do eb:CreateTexture("ChatFrameEditBox" .. n, "BACKGROUND") end
    eb:CreateFontString("ChatFrameEditBoxHeader", "OVERLAY")
    env.ChatTypeInfo = {
        SAY = { r = 1, g = 1, b = 1, sticky = 1 }, GUILD = { r = 0.25, g = 1, b = 0.25, sticky = 0 },
        WHISPER = { r = 1, g = 0.5, b = 1, sticky = 0 }, PARTY = { r = 0.67, g = 0.67, b = 1, sticky = 0 },
        RAID = { r = 1, g = 0.5, b = 0, sticky = 0 }, OFFICER = { r = 0.25, g = 0.75, b = 0.25, sticky = 0 },
        CHANNEL = { r = 1, g = 0.75, b = 0.75, sticky = 0 },
    }
    env.__flashed = 0
    env.FCF_FlashTab = function() env.__flashed = env.__flashed + 1 end
    env.__dock_updates = 0
    env.FCF_DockUpdate = function() env.__dock_updates = env.__dock_updates + 1 end
    env.FCF_UpdateDockPosition = function()      -- the stock code re-places the frame over the bars
        env.ChatFrame1:ClearAllPoints()
        env.ChatFrame1:SetPoint("BOTTOMLEFT", env.UIParent, "BOTTOMLEFT", 32, 110)
    end
    env.ChatEdit_UpdateHeader = function(box)
        env.ChatFrameEditBoxHeader:SetText((box.chatType or "SAY") .. ":")
    end
end

local function chat(opts)
    opts = opts or {}
    local env = T.client(opts)
    stockPieces(env)
    api.load_with_deps(env, "Chat")
    if opts.themes then api.load_with_deps(env, "Themes") end
    api.login(env)
    return env
end

local function pair(optsA, optsB)
    local A = chat(optsA or { name = "Herald", class = "HUNTER", guild = { name = "Ashen Vanguard", members = 12 } })
    local B = T.suite(optsB or { name = "Berra", class = "MAGE", guild = { name = "Ashen Vanguard", members = 12 } })
    return A, B
end

local function lines(env, frame) return api.state(frame or env.ChatFrame1).messages or {} end
local function last(env, frame) local l = lines(env, frame) return l[#l] end
local function lastVisible(env, frame) return api.visible(last(env, frame) or "") end
local function setting(env, key, v) env.ClassicPlus_Manager:SetSetting("Chat", key, v) end

-- -- registration ------------------------------------------------------------------------------

T.test("Chat: registers as its own addon with every option in the Addons window", function()
    local env = chat()
    local W = env.WenillaCore
    T.ok(W.schemas.Chat, "schema")
    T.eq(W.schemas.Chat.title, "Chat")
    local n, kinds = 0, {}
    for _, o in ipairs(W.schemas.Chat.options) do n = n + 1; kinds[o.type or "switch"] = (kinds[o.type or "switch"] or 0) + 1 end
    T.eq(n, 22, "options")
    T.eq(kinds.choice, 4); T.eq(kinds.slider, 2); T.eq(kinds.switch, 16)
    local found = false
    for _, id in ipairs(W.ADDONS) do if id == "Chat" then found = true end end
    T.ok(found, "listed in the Addons window")
    env.ClassicPlus_ToggleManager()
    env.ClassicPlus_Manager:SelectAddon("Chat")
    T.ok(env.ClassicPlus_OptCB13, "room for a 13th switch row")
    local M = env.ClassicPlus_Manager
    M.scroll = M.contentHeight - 300
    M:LayoutOptions()
    T.shown(env.ClassicPlus_OptCB13, "13th switch row, scrolled into view")
    T.ok(env.CPChat.active)
    -- the old WenillaCore chat file is gone; its globals now come from the Chat addon
    T.ok(env.SlashCmdList.CPCHAT, "/cpchat")
end)

T.test("Chat: the default look is the opaque Slate panel, raised above the action bars", function()
    local env = chat()
    local k = env.ChatFrame1.cpSkin
    T.shown(k.panel, "panel")
    T.has(k.panel.face:GetTexture(), "Chat_Panel", "panel art")
    T.lacks(k.panel.face:GetTexture(), "Chat_Panel_", "Slate's art is plain Chat_Panel")
    T.near(k.panel.face:GetAlpha(), 0.85, 0.001, "85% opacity")
    T.shown(k.panel.top, "1 px light top edge")
    T.has(k.shadow.TL:GetTexture(), "Chat_Shadow", "soft shadow")
    T.ok(k.shadow.TL:IsShown())
    T.has(k.panel.edge.TL:GetTexture(), "Chat_Edge")
    local p, _, _, x, y = env.ChatFrame1:GetPoint(1)
    T.eq(p, "BOTTOMLEFT"); T.eq(x, 32); T.eq(y, 95 + 72, "moved up 72 px (Chat/Skin.lua C.RAISE)")
    env.FCF_UpdateDockPosition()
    local _, _, _, _, y2 = env.ChatFrame1:GetPoint(env.ChatFrame1:GetNumPoints())
    T.eq(y2, 110 + 72, "still 72 px above where the stock code puts it")
    -- stock bits hidden: four scroll buttons, the emote bubble, the old background
    T.hidden(env.ChatFrame1UpButton); T.hidden(env.ChatFrame1DownButton); T.hidden(env.ChatFrame1BottomButton)
    T.hidden(env.ChatFrameMenuButton)
    T.hidden(env.ChatFrame1Background)
    env.ChatFrame1UpButton:Show()
    T.hidden(env.ChatFrame1UpButton, "FCF cannot bring a scroll button back")
    -- outlined text, 1 px spacing, size 13
    local _, size, flags = env.ChatFrame1:GetFont()
    T.eq(size, 13); T.eq(flags, "OUTLINE")
    -- the tab bar
    T.shown(env.CPChatMenuButton); T.shown(env.CPChatCopyButton)
    T.eq(env.ChatFrame1Tab:GetHeight(), 20)
    T.hidden(env.ChatFrame1TabLeft, "stock tab art hidden")
    T.eq(env.ChatFrame1Tab.cpLine:GetAlpha(), 1, "active tab underline")
    T.eq(env.ChatFrame2Tab.cpLine:GetAlpha(), 0)
    -- the input line sits in the panel, the channel in its colour
    local eb = env.ChatFrameEditBox
    local ep, rel = eb:GetPoint(1)
    T.eq(ep, "BOTTOMLEFT"); T.eq(rel, env.ChatFrame1)
    T.hidden(env.ChatFrameEditBoxLeft)
    eb.chatType = "GUILD"
    env.ChatEdit_UpdateHeader(eb)
    local r, g, b = env.ChatFrameEditBoxHeader:GetTextColor()
    T.near(r, 0.25, 0.01); T.near(g, 1, 0.01); T.near(b, 0.25, 0.01)
    T.eq(env.ChatFrameEditBoxHeader:GetText(), "GUILD:")
end)

T.test("Chat: five themes, each with its own panel, tab and edge art", function()
    local env = chat()
    local k = env.ChatFrame1.cpSkin
    local tab = env.ChatFrame1Tab
    for _, key in ipairs({ "parchment", "midnight", "wildwood", "glass", "slate" }) do
        setting(env, "theme", key)
        local suffix = (key == "slate") and "" or ("_" .. string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2))
        T.has(k.panel.face:GetTexture(), "Chat_Panel" .. suffix, key .. " panel")
        T.has(tab.cpBg:GetTexture(), "Chat_Tab" .. suffix, key .. " tab")
        T.has(k.panel.edge.TL:GetTexture(), "Chat_Edge" .. suffix, key .. " edge")
        local c = env.CPChat.THEMES[key].accent
        local r, g, b = unpack(api.state(tab.cpLine).color or { 0, 0, 0 })
        T.near(r, c[1], 0.01, key .. " accent")
        T.near(g, c[2], 0.01)
    end
    -- Wildwood's carved frame is thick; Glass has no shadow
    setting(env, "theme", "wildwood")
    T.eq(k.panel.edge.TL:GetWidth(), 14)
    setting(env, "theme", "glass")
    T.ok(not k.shadow.TL:IsShown(), "glass: no shadow")
    -- a theme that does not exist falls back to Slate
    setting(env, "theme", "neon")
    T.has(k.panel.face:GetTexture(), "Chat_Panel")
    T.eq(env.CPChat:Theme().label, "Slate")
end)

T.test("Chat: Parchment writes in dark ink, and switching away gives the colours back", function()
    local A, B = pair()
    B.SendChatMessage("hello there", "SAY")
    api.pump(A)
    local before = last(A)
    setting(A, "theme", "parchment")
    local inked = last(A)
    T.has(api.visible(inked), "[Berra] says: hello there", "same words")
    T.ok(inked ~= before, "line re-printed in ink")
    T.has(inked, "|c", "ink colours")
    local _, _, flags = A.ChatFrame1:GetFont()
    T.eq(flags, "", "no outline on paper")
    setting(A, "theme", "slate")
    T.eq(last(A), before, "back to the original line")
end)

T.test("Chat: the opacity slider runs from 40 to 100 percent", function()
    local env = chat()
    local k = env.ChatFrame1.cpSkin
    setting(env, "opacity", 40)
    T.near(k.panel.face:GetAlpha(), 0.40, 0.001)
    setting(env, "opacity", 100)
    T.near(k.panel.face:GetAlpha(), 1, 0.001)
    setting(env, "opacity", 10)
    T.near(k.panel.face:GetAlpha(), 0.40, 0.001, "clamped to 40%")
    local o
    for _, x in ipairs(env.WenillaCore.schemas.Chat.options) do if x.key == "opacity" then o = x end end
    T.eq(o.min, 40); T.eq(o.max, 100)
end)

T.test("Chat: text size and fading follow the settings", function()
    local env = chat()
    setting(env, "fontSize", 16)
    local _, size = env.ChatFrame1:GetFont()
    T.eq(size, 16)
end)

-- -- the lines ---------------------------------------------------------------------------------

T.test("Chat: timestamps off, 24-hour and 12-hour", function()
    local A, B = pair()
    B.SendChatMessage("one", "SAY"); api.pump(A)
    T.ok(string.find(lastVisible(A), "^%d%d:%d%d %[Berra%] says: one$"), "24 h by default: " .. lastVisible(A))
    setting(A, "timestamps", "12")
    B.SendChatMessage("two", "SAY"); api.pump(A)
    T.ok(string.find(lastVisible(A), "^%d%d?:%d%d[ap]m %[Berra%] says: two$"), "12 h: " .. lastVisible(A))
    setting(A, "timestamps", "off")
    B.SendChatMessage("three", "SAY"); api.pump(A)
    T.eq(lastVisible(A), "[Berra] says: three")
    -- the old switch still works
    A.__slash("/cpchat timestamps")
    T.eq(A.CPChat:Get("timestamps"), "24")
end)

T.test("Chat: short channel names, with a setting to keep the full ones", function()
    local A, B = pair()
    setting(A, "timestamps", "off")
    B.SendChatMessage("WTS linen", "CHANNEL", nil, B.GetChannelName("Trade")); api.pump(A)
    T.eq(lastVisible(A), "[T] [Berra]: WTS linen")
    B.SendChatMessage("hi all", "CHANNEL", nil, B.GetChannelName("General")); api.pump(A)
    T.eq(lastVisible(A), "[1] [Berra]: hi all")
    B.SendChatMessage("hi guild", "GUILD"); api.pump(A)
    T.eq(lastVisible(A), "[G] [Berra]: hi guild")
    B.JoinChannelByName("LookingForGroup"); A.JoinChannelByName("LookingForGroup"); api.pump(A)
    B.SendChatMessage("LF2M", "CHANNEL", nil, B.GetChannelName("LookingForGroup")); api.pump(A)
    T.eq(lastVisible(A), "[LFG] [Berra]: LF2M")
    T.eq(A.CPChat:ShortChannel("[Party] [X]: y"), "[P] [X]: y")
    T.eq(A.CPChat:ShortChannel("[Raid] [X]: y"), "[R] [X]: y")
    T.eq(A.CPChat:ShortChannel("[7. world] [X]: y"), "[W] [X]: y", "the realm-wide World channel (chat_world.lua)")
    T.eq(A.CPChat:ShortChannel("[8. worldbosses] [X]: y"), "[8] [X]: y", "only World itself")
    setting(A, "channelNames", "full")
    B.SendChatMessage("WTS wool", "CHANNEL", nil, B.GetChannelName("Trade")); api.pump(A)
    T.eq(lastVisible(A), "[2. Trade] [Berra]: WTS wool")
end)

T.test("Chat: guild members are class-coloured from the roster", function()
    local A, B = pair()
    B.SendChatMessage("hi guild", "GUILD"); api.pump(A)
    T.eq(A.ClassicPlus_Chat.classes.Berra, "MAGE")
    T.has(last(A), "Berra|r]")
end)

T.test("Chat: names in class colours once the player has been seen", function()
    local A, B = pair(nil, { name = "Berra", class = "MAGE" })
    B.SendChatMessage("first", "SAY"); api.pump(A)
    T.lacks(last(A), "Berra|r", "unknown class: plain")
    api.set_target(A, "Berra")
    B.SendChatMessage("second", "SAY"); api.pump(A)
    local c = A.RAID_CLASS_COLORS.MAGE
    T.has(last(A), "[|cff" .. A.CPChat.Hex(c.r, c.g, c.b) .. "Berra|r]", "mage blue")
    T.eq(A.ClassicPlus_Chat.classes.Berra, "MAGE", "remembered account-wide")
    -- a player link keeps working
    T.eq(A.CPChat:ColourName("|Hplayer:Berra|h[Berra]|h: hi", "Berra"), "|Hplayer:Berra|h[|cff" .. A.CPChat.Hex(c.r, c.g, c.b) .. "Berra|r]|h: hi")
    setting(A, "classColors", false)
    B.SendChatMessage("third", "SAY"); api.pump(A)
    T.lacks(last(A), "Berra|r", "switched off")
end)

T.test("Chat: web links are clickable and open a copy box", function()
    local A, B = pair()
    B.SendChatMessage("guide at www.openvanilla.gg/guide, see you", "SAY"); api.pump(A)
    T.has(last(A), "|Hurl:www.openvanilla.gg/guide|h[www.openvanilla.gg/guide]|h|r, see you", "link, comma kept outside")
    T.eq(A.CPChat:Linkify("e.g. ok... v1.12 is fine"), "e.g. ok... v1.12 is fine", "not everything with a dot is a link")
    T.has(A.CPChat:Linkify("https://example.org/a?b=1"), "|Hurl:https://example.org/a?b=1|h")
    T.has(A.CPChat:Linkify("join discord.gg/openvanilla"), "|Hurl:discord.gg/openvanilla|h")
    A.SetItemRef("url:www.openvanilla.gg/guide", "[www.openvanilla.gg/guide]", "LeftButton")
    T.shown(A.CPChatLink, "link box")
    T.eq(A.CPChatLinkBox:GetText(), "www.openvanilla.gg/guide")
    T.eq(A.__focus, A.CPChatLinkBox, "focused, ready for Ctrl+C")
    api.type(A.CPChatLinkBox, "oops")
    T.eq(A.CPChatLinkBox:GetText(), "www.openvanilla.gg/guide", "read-only")
    setting(A, "links", false)
    B.SendChatMessage("www.example.com", "SAY"); api.pump(A)
    T.lacks(last(A), "|Hurl:")
end)

T.test("Chat: Copy chat puts the last 200 lines in a selectable box", function()
    local env = chat()
    for i = 1, 250 do env.ChatFrame1:AddMessage("line |cffff0000number|r " .. i) end
    api.click(env.CPChatCopyButton)
    T.shown(env.CPChatCopy)
    local text = env.CPChatCopyBox:GetText()
    local n = 0
    for _ in string.gmatch(text, "[^\n]+") do n = n + 1 end
    T.eq(n, 200)
    T.ok(string.find(text, "^%d%d:%d%d line number 51\n"), "starts at line 51, colour codes removed")
    T.ok(string.find(text, "line number 250$"))
    T.lacks(text, "|c")
    T.eq(env.__focus, env.CPChatCopyBox)
    api.press_escape(env)
    T.hidden(env.CPChatCopy)
    env.__slash("/cpchat copy")
    T.shown(env.CPChatCopy)
end)

T.test("Chat: repeats collapse into one line with a count", function()
    local A, B = pair()
    setting(A, "timestamps", "off")
    local n0 = #lines(A)
    for _ = 1, 3 do B.SendChatMessage("LF healer for SM", "SAY"); api.pump(A) end
    T.eq(#lines(A), n0 + 1, "one line")
    T.eq(lastVisible(A), "[Berra] says: LF healer for SM \195\1513")
    B.SendChatMessage("anyone?", "SAY"); api.pump(A)
    B.SendChatMessage("LF healer for SM", "SAY"); api.pump(A)
    T.eq(lastVisible(A), "[Berra] says: LF healer for SM", "a new streak starts over")
    -- scrolled up: the count still goes up, the view is not yanked down
    A.ChatFrame1:ScrollUp()
    B.SendChatMessage("LF healer for SM", "SAY"); api.pump(A)
    T.eq(A.ChatFrame1:GetCurrentScroll(), 1)
    T.has(A.ChatFrame1.cpLines[#A.ChatFrame1.cpLines].text, "\195\1512")
    setting(A, "collapse", false)
    local n1 = #lines(A)
    B.SendChatMessage("same", "SAY"); api.pump(A)
    B.SendChatMessage("same", "SAY"); api.pump(A)
    T.eq(#lines(A), n1 + 2, "off: every line shows")
end)

T.test("Chat: the gold-seller filter is optional and only hides adverts", function()
    local A, B = pair()
    local ad = "CHEAP G0LD fast delivery 100g = 5 USD w w w . goldshop . c0m"
    B.SendChatMessage(ad, "CHANNEL", nil, B.GetChannelName("Trade")); api.pump(A)
    T.has(lastVisible(A), "CHEAP G0LD", "off by default")
    setting(A, "goldFilter", true)
    local n = #lines(A)
    B.SendChatMessage("WTS gold ore, cheap, visit www.goldshop.com", "CHANNEL", nil, B.GetChannelName("Trade")); api.pump(A)
    B.SendChatMessage(ad, "SAY"); api.pump(A)
    T.eq(#lines(A), n, "adverts hidden")
    T.eq(A.CPChat.filtered, 2)
    B.SendChatMessage("selling gold ore in Ironforge", "CHANNEL", nil, B.GetChannelName("Trade")); api.pump(A)
    B.SendChatMessage("guide: www.openvanilla.gg", "SAY"); api.pump(A)
    B.SendChatMessage("gold run tonight, see www.openvanilla.gg", "GUILD"); api.pump(A)
    T.eq(#lines(A), n + 3, "ordinary lines and guild chat stay")
end)

T.test("Chat: what you typed comes back after a reload", function()
    local env = chat()
    local eb = env.ChatFrameEditBox
    eb:AddHistoryLine("/dance")                  -- the stock ChatEdit_AddHistory path
    api.type(eb, "hello world")
    api.press_enter(eb)                          -- a client that adds nothing itself
    eb:AddHistoryLine("hello world")             -- the same line twice in a row is kept once
    T.eq(table.concat(env.ClassicPlus_ChatHistory.lines, "|"), "/dance|hello world")
    for i = 1, 60 do eb:AddHistoryLine("l" .. i) end
    T.eq(#env.ClassicPlus_ChatHistory.lines, 50, "capped")
    local again = T.relog(env)
    T.eq(again.CPChat.historyLoaded, 50, "put back into the edit box")
    T.eq(again.ClassicPlus_ChatHistory.lines[50], "l60")
    -- off: nothing is remembered
    again.ClassicPlus_Manager:SetSetting("Chat", "typedHistory", false)
    again.ChatFrameEditBox:AddHistoryLine("secret")
    T.lacks(table.concat(again.ClassicPlus_ChatHistory.lines, "|"), "secret")
end)

T.test("Chat: your name is highlighted, with a soft sound, and can be muted per tab", function()
    local A, B = pair()
    setting(A, "timestamps", "off")
    B.SendChatMessage("herald, ready?", "SAY"); api.pump(A)
    T.has(last(A), "|cffff9e2eherald|r, ready?", "highlighted")
    T.eq(A.__sounds[#A.__sounds], "MapPing")
    local s = #A.__sounds
    B.SendChatMessage("Herald!!", "SAY"); api.pump(A)
    T.eq(#A.__sounds, s, "no second ping within a few seconds")
    B.SendChatMessage("the heralds are here", "SAY"); api.pump(A)
    T.lacks(last(A), "|cffff9e2e", "whole words only")
    A.SendChatMessage("I am Herald", "SAY"); api.pump(A)
    T.lacks(last(A), "|cffff9e2e", "not your own lines")
    -- the tab bar menu turns it off for this tab
    api.click(A.CPChatMenuButton)
    api.click_text(A, "Highlight my name in this tab")
    B.SendChatMessage("herald?", "SAY"); api.pump(A)
    T.lacks(last(A), "|cffff9e2e", "muted in this tab")
    T.eq(A.WenillaCore_Config.settings.Chat.mentionOff.ChatFrame1, true)
end)

T.test("Chat: new lines in a hidden tab show a dot instead of a flash", function()
    local env = chat()
    local C = env.CPChat
    env.this = env.ChatFrame2
    env.FCF_FlashTab()
    env.this = nil
    T.eq(env.__flashed, 0, "the stock flash is not used")
    T.eq(env.ChatFrame2Tab.cpDot:GetAlpha(), 1, "dot on Combat Log")
    T.eq(env.ChatFrame1Tab.cpDot:GetAlpha(), 0)
    env.SELECTED_DOCK_FRAME = env.ChatFrame2
    api.tick(env, 0.5)
    T.eq(env.ChatFrame2Tab.cpDot:GetAlpha(), 0, "selecting clears it")
    T.eq(env.ChatFrame2Tab.cpLine:GetAlpha(), 1, "and moves the underline")
    -- a mention in a hidden tab is a gold-orange dot
    env.SELECTED_DOCK_FRAME = env.ChatFrame1
    api.tick(env, 0.5)
    C:MarkUnread(env.ChatFrame2, true)
    local r, g = env.ChatFrame2Tab.cpDot:GetVertexColor()
    T.near(r, 1, 0.01); T.near(g, 0.62, 0.01)
end)

T.test("Chat: whisper tabs give each conversation its own tab", function()
    local A, B = pair()
    setting(A, "whisperTabs", true)
    setting(A, "timestamps", "off")
    local n = #lines(A)
    B.SendChatMessage("psst, got a sec?", "WHISPER", nil, "Herald"); api.pump(A)
    T.eq(#lines(A), n, "not in the main window")
    T.shown(A.CPChatWhisperTab1)
    T.eq(A.CPChatWhisperTab1.label:GetText(), "Berra")
    T.eq(A.CPChatWhisperTab1.cpDot:GetAlpha(), 1, "unread")
    api.click(A.CPChatWhisperTab1)
    T.shown(A.CPChatWhisperFrame)
    T.hidden(A.ChatFrame1, "main window put away while reading")
    T.has(api.visible(api.state(A.CPChatWhisperFrame).messages[1]), "[Berra] whispers: psst, got a sec?")
    T.eq(A.CPChatWhisperTab1.cpLine:GetAlpha(), 1, "selected")
    T.eq(A.ChatFrame1Tab.cpLine:GetAlpha(), 0)
    -- Enter writes to Berra
    A.ChatFrame_OpenChat("")
    T.eq(A.ChatFrameEditBox.chatType, "WHISPER"); T.eq(A.ChatFrameEditBox.tellTarget, "Berra")
    A.SendChatMessage("sure", "WHISPER", nil, "Berra"); api.pump(A)
    T.has(api.visible(api.state(A.CPChatWhisperFrame).messages[2]), "To [Berra]: sure")
    -- back to General
    api.click(A.ChatFrame1Tab)
    T.hidden(A.CPChatWhisperFrame)
    T.shown(A.ChatFrame1)
    -- right-click closes the conversation
    api.click(A.CPChatWhisperTab1, "RightButton")
    T.hidden(A.CPChatWhisperTab1)
    -- off: whispers are back in the main window
    setting(A, "whisperTabs", false)
    B.SendChatMessage("hello?", "WHISPER", nil, "Herald"); api.pump(A)
    T.eq(lastVisible(A), "[Berra] whispers: hello?")
end)

-- -- the window --------------------------------------------------------------------------------

T.test("Chat: the chrome fades after 20 s of quiet, or never", function()
    local env = chat()
    local k = env.ChatFrame1.cpSkin
    api.tick(env, 10)
    T.eq(k.panel:GetAlpha(), 1)
    for _ = 1, 30 do api.tick(env, 1) end
    T.eq(k.panel:GetAlpha(), 0, "faded")
    T.eq(env.ChatFrame1Tab:GetAlpha(), 0, "tabs fade with it")
    env.ChatFrame1:AddMessage("wake up")
    for _ = 1, 5 do api.tick(env, 0.1) end
    T.eq(k.panel:GetAlpha(), 1, "a new line brings it back")
    env.ChatFrame1Tab:SetAlpha(0)
    T.eq(env.ChatFrame1Tab:GetAlpha(), 1, "the stock tab fade cannot hide our tabs")
    setting(env, "fade", "never")
    for _ = 1, 30 do api.tick(env, 1) end
    T.eq(k.panel:GetAlpha(), 1, "never fades")
end)

T.test("Chat: scrolled up shows a jump-to-latest arrow; hover shows a thin scrollbar", function()
    local env = chat()
    local f = env.ChatFrame1
    local k = f.cpSkin
    for i = 1, 40 do f:AddMessage("line " .. i) end
    api.tick(env, 0.1)
    T.hidden(k.jump)
    f:ScrollUp(); f:ScrollUp()
    api.tick(env, 0.1)
    T.shown(k.jump, "jump arrow")
    api.click(k.jump)
    T.eq(f:GetCurrentScroll(), 0)
    T.hidden(k.jump)
    T.hidden(k.bar, "no scrollbar until hover")
    env.MouseIsOver = function(fr) return fr == k.panel end
    api.tick(env, 0.1)
    T.shown(k.bar, "thin scrollbar on hover")
    T.shown(k.grip, "resize grip on hover")
    env.MouseIsOver = function() return false end
    api.tick(env, 0.1)
    T.hidden(k.bar)
    -- the mouse wheel still scrolls (Shift jumps)
    api.wheel(f, 1)
    T.eq(f:GetCurrentScroll(), 1)
end)

T.test("Chat: moving and resizing snap to the grid and the screen edges; Move lists the chat", function()
    local env = chat({ themes = true })
    local f = env.ChatFrame1
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", env.UIParent, "BOTTOMLEFT", 5, 203)
    env.CPChat:Snap(f)
    local p, _, _, x, y = f:GetPoint(1)
    T.eq(p, "BOTTOMLEFT")
    T.eq(x, 10, "snapped to the left edge")
    T.eq(y, 84, "on the 4 px grid")
    local found
    for _, e in ipairs(env.ClassicPlusUI.registry) do if e[1] == "ChatFrame1" then found = e[2] end end
    T.eq(found, "Chat", "Move Anything knows the chat")
end)

T.test("Chat: the tab bar menu has emotes, copy, themes and settings", function()
    local env = chat()
    env.ChatMenu = env.CreateFrame("Frame", "ChatMenu", env.UIParent)
    env.ChatMenu:Hide()
    api.click(env.CPChatMenuButton)
    T.shown(env.WenillaCore_Menu)
    T.ok(api.screen_has(env, "Emotes and speech", env.WenillaCore_Menu))
    api.click_text(env, "Emotes and speech")
    T.shown(env.ChatMenu, "the stock emote and voice menu")
    api.click(env.CPChatMenuButton)
    api.click_text(env, "Midnight")
    T.eq(env.CPChat:Get("theme"), "midnight")
    api.click(env.CPChatMenuButton)
    api.click_text(env, "All chat settings...")
    T.shown(env.ClassicPlus_SettingsWindow)
end)

T.test("Chat: an interface theme can choose the chat theme", function()
    local env = chat()
    env.ClassicPlusUI = env.ClassicPlusUI or {}
    env.ClassicPlusUI.chatTheme = "wildwood"
    env.WenillaCore:Refresh("Chat")
    T.eq(env.CPChat:Get("theme"), "wildwood")
    setting(env, "theme", "glass")
    T.eq(env.CPChat:Get("theme"), "glass", "the player's own pick wins afterwards")
    env.CPChat:FollowTheme("midnight")
    T.eq(env.CPChat:Get("theme"), "midnight")
end)

T.test("Chat: older options carry over and /cpchat still toggles them", function()
    local env = chat({ saved = { ClassicPlus_Defaults = { chat = { wheel = false, timestamps = false, alerts = false } } } })
    local C = env.CPChat
    T.eq(C:Get("wheel"), false); T.eq(C:Get("timestamps"), "off"); T.eq(C:Get("alerts"), false)
    T.eq(env.GetCVar("guildMemberNotify"), "0")
    env.__slash("/cpchat alerts")
    T.eq(env.GetCVar("guildMemberNotify"), "1")
    T.eq(env.ChatTypeInfo.WHISPER.sticky, 1, "sticky whispers")
    env.__slash("/cpchat sticky")
    T.eq(env.ChatTypeInfo.WHISPER.sticky, 0, "back to stock")
    env.__slash("/cpchat theme midnight")
    T.eq(C:Get("theme"), "midnight")
    T.has(api.chat_text(env), "Chat theme: Midnight")
end)

T.test("Chat: turning the addon off restores the stock chat exactly", function()
    local A, B = pair()
    local f, tab, eb = A.ChatFrame1, A.ChatFrame1Tab, A.ChatFrameEditBox
    A.WenillaCore:SetAddonEnabled("Chat", false)
    T.hidden(f.cpSkin.panel)
    T.hidden(A.CPChatBar)
    T.shown(A.ChatFrame1UpButton); T.shown(A.ChatFrame1DownButton); T.shown(A.ChatFrame1BottomButton)
    T.shown(A.ChatFrameMenuButton)
    T.shown(A.ChatFrame1Background)
    T.shown(A.ChatFrame1TabLeft)
    T.eq(rawget(tab, "SetAlpha"), nil, "tab fades work again")
    T.eq(rawget(A.ChatFrame1UpButton, "Show"), nil)
    T.eq(tab:GetHeight(), 32); T.eq(tab:GetWidth(), 64)
    local tp, trel, _, tx, ty = tab:GetPoint(1)
    T.eq(tp, "BOTTOMLEFT"); T.eq(trel, f); T.eq(tx, 2); T.eq(ty, -4)
    local ep, erel, erp, ex, ey = eb:GetPoint(1)
    T.eq(ep, "TOPLEFT"); T.eq(erel, f); T.eq(erp, "BOTTOMLEFT"); T.eq(ex, -5); T.eq(ey, -2)
    T.eq(eb:GetHeight(), 32)
    T.ok(A.ChatFrameEditBoxLeft:IsShown(), "stock edit box art back")
    local p, _, _, _, y = f:GetPoint(1)
    T.eq(p, "BOTTOMLEFT"); T.eq(y, 95, "back down")
    T.eq(A.ChatTypeInfo.WHISPER.sticky, 0)
    T.ok(A.__flashed == 0)
    A.this = A.ChatFrame2; A.FCF_FlashTab(); A.this = nil
    T.eq(A.__flashed, 1, "the stock tab flash is back")
    T.ok(A.__dock_updates > 0, "stock tabs laid out again")
    -- lines pass through untouched
    B.SendChatMessage("plain www.openvanilla.gg", "CHANNEL", nil, B.GetChannelName("Trade")); api.pump(A)
    T.eq(last(A), "[2. Trade] [Berra]: plain www.openvanilla.gg")
    -- and on again
    A.WenillaCore:SetAddonEnabled("Chat", true)
    T.shown(f.cpSkin.panel)
    T.hidden(A.ChatFrame1UpButton)
    local _, _, _, _, y2 = f:GetPoint(1)
    T.eq(y2, 95 + 72)
    -- Pure Vanilla turns it off too
    A.WenillaCore:SetVanillaMode(true)
    T.hidden(f.cpSkin.panel)
    T.shown(A.ChatFrameMenuButton)
end)

T.test("Chat: without the art the window still looks right (flat colours)", function()
    local env = chat({ art = false })
    local k = env.ChatFrame1.cpSkin
    T.shown(k.panel)
    T.eq(k.panel.face:GetTexture(), nil)
    T.ok(k.panel.lines.LEFT:IsShown(), "thin flat edge")
    T.ok(not k.shadow.TL:IsShown())
    setting(env, "theme", "parchment")
    T.ok(k.panel.lines.TOP:IsShown())
end)

T.test("Chat: other addons' chat hooks keep working", function()
    local env = chat()
    local seen = {}
    local inner = env.ChatFrame1.AddMessage
    env.ChatFrame1.AddMessage = function(self, msg, r, g, b, id)
        table.insert(seen, msg)
        return inner(self, "[hooked] " .. msg, r, g, b, id)
    end
    env.ChatFrame1:AddMessage("hi")
    T.eq(seen[1], "hi")
    T.has(last(env), "[hooked] hi")
    -- WenillaCore's carrier lines are still hidden
    api.fire(env, "CHAT_MSG_SYSTEM", "WNL\tZZ secret")
    T.lacks(api.chat_text(env), "WNL")
end)

T.test("Chat: the expanded view shows the whole history, filters by search, follows new lines and maximizes", function()
    local env = chat()
    for i = 1, 600 do env.ChatFrame1:AddMessage("line |cffff0000number|r " .. i .. (i == 333 and " dragon" or "")) end
    T.shown(env.CPChatExpandButton, "a button on the tab bar, beside Copy")
    api.click(env.CPChatExpandButton)
    T.shown(env.CPChatExpanded)
    local m = api.state(env.CPChatExpandedLines).messages or {}
    local total = table.getn(env.ChatFrame1.cpLines)
    T.ok(total >= 600)
    T.eq(table.getn(m), total, "every buffered line, not just the last 200")
    T.has(env.CPChatExpanded.count:GetText(), total .. " lines")
    T.has(env.CPChatExpanded.head:GetText(), "General")
    -- search: colour codes ignored, case-insensitive
    api.type(env.CPChatExpandedSearch, "DRAGON")
    m = api.state(env.CPChatExpandedLines).messages or {}
    T.eq(table.getn(m), 1)
    T.has(m[1], "dragon")
    T.has(env.CPChatExpanded.count:GetText(), "1 of " .. total)
    api.type(env.CPChatExpandedSearch, "no such words")
    T.shown(env.CPChatExpanded.empty)
    api.type(env.CPChatExpandedSearch, "")
    -- a new line arrives while it is open
    env.ChatFrame1:AddMessage("fresh news")
    api.tick(env, 1)
    m = api.state(env.CPChatExpandedLines).messages or {}
    T.eq(table.getn(m), total + 1)
    T.has(m[total + 1], "fresh news")
    -- maximize and back
    local w = env.CPChatExpanded:GetWidth()
    env.CPChat:ToggleExpandSize()
    T.ok(env.CPChatExpanded:GetWidth() > w, "bigger")
    T.eq(env.CPChatExpanded.max:GetText(), "Restore")
    env.CPChat:ToggleExpandSize()
    T.eq(env.CPChatExpanded:GetWidth(), w)
    -- Escape closes; /cpchat expand and the chat menu open it again
    api.press_escape(env)
    T.hidden(env.CPChatExpanded)
    env.__slash("/cpchat expand")
    T.shown(env.CPChatExpanded)
    api.press_escape(env)
    api.click(env.CPChatMenuButton)
    api.click_text(env, "Expanded view", env.WenillaCore_Menu)
    T.shown(env.CPChatExpanded)
end)
