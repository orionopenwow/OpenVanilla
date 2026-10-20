-- Chat: the World tab — the realm-wide World channel (server patch 0007, faked by ext/world.lua)
-- and the Discord #world bridge's [D] lines (Herald -> ".wnl worldsay" -> "WD W,<name>,<text>"),
-- the [W] short name, the channel cycle, /world, and the three settings.
local T, api = ...

-- The stock chat pieces the skin restyles (as in chat.lua), then Chat loaded, logged in, greeted
-- by the server and put in World the way the server does it at login.
local function stockPieces(env)
    env.CreateFrame("Button", "ChatFrameMenuButton", env.UIParent)
    for i = 1, 2 do
        local f = env["ChatFrame" .. i]
        for _, b in ipairs({ "UpButton", "DownButton", "BottomButton" }) do env.CreateFrame("Button", "ChatFrame" .. i .. b, f) end
        local tab = env["ChatFrame" .. i .. "Tab"]
        for _, n in ipairs({ "Left", "Middle", "Right", "Flash" }) do tab:CreateTexture("ChatFrame" .. i .. "Tab" .. n, "BACKGROUND") end
        tab:CreateFontString("ChatFrame" .. i .. "TabText", "OVERLAY"):SetText(i == 1 and "General" or "Combat Log")
        tab:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 2 + (i - 1) * 70, -4)
        tab:SetHeight(32)
        tab:SetWidth(64)
    end
    env.ChatFrame1.isDocked, env.ChatFrame2.isDocked = 1, 1
    env.DOCKED_CHAT_FRAMES = { env.ChatFrame1, env.ChatFrame2 }
    env.SELECTED_DOCK_FRAME = env.ChatFrame1
    local eb = env.ChatFrameEditBox
    eb:SetPoint("TOPLEFT", env.ChatFrame1, "BOTTOMLEFT", -5, -2)
    eb:SetHeight(32)
    eb:CreateFontString("ChatFrameEditBoxHeader", "OVERLAY")
    env.ChatTypeInfo = {
        SAY = { r = 1, g = 1, b = 1 }, GUILD = { r = 0.25, g = 1, b = 0.25 }, WHISPER = { r = 1, g = 0.5, b = 1 },
        PARTY = { r = 0.67, g = 0.67, b = 1 }, CHANNEL = { r = 1, g = 0.75, b = 0.75 },
    }
    env.ChatEdit_UpdateHeader = function(box)
        local h = box.chatType or "SAY"
        if h == "CHANNEL" then h = h .. tostring(box.channelTarget) end
        env.ChatFrameEditBoxHeader:SetText(h .. ":")
    end
    env.__chat_channels = {}
    env.ChatFrame_AddChannel = function(f, name) env.__chat_channels[name] = f end
    env.ChatFrame_RemoveChannel = function(f, name) env.__chat_channels[name] = nil end
end

local GUILD = { name = "Ashen Vanguard", members = 12 }

local function chat(opts, worldOpts)
    opts = opts or { name = "Herald", class = "HUNTER", guild = GUILD }
    local env = T.client(opts)
    stockPieces(env)
    api.load_with_deps(env, "Chat")
    api.login(env)
    api.connect(env)
    api.world_server(env, worldOpts)
    env.ClassicPlus_Manager:SetSetting("Chat", "timestamps", "off")
    return env
end

local function pair(worldOpts)
    local A = chat(nil, worldOpts)
    local B = T.suite({ name = "Berra", class = "MAGE", guild = GUILD })
    api.connect(B)
    api.world_server(B)
    return A, B
end

local function setting(env, key, v) env.ClassicPlus_Manager:SetSetting("Chat", key, v) end
local function worldLines(env) return env.CPChat.world.lines end
local function lastWorld(env) local l = worldLines(env) return l[#l] and l[#l].text end
-- what the player reads: colours and link codes gone
local function seen(s)
    s = string.gsub(s or "", "|H[^|]*|h(.-)|h", "%1")
    return api.visible(s)
end
local function mainLines(env) return api.state(env.ChatFrame1).messages or {} end
local function lastMain(env) local l = mainLines(env) return api.visible(l[#l] or "") end
local function sent(env)
    local out = {}
    for _, l in ipairs(env.__wnl) do out[l] = (out[l] or 0) + 1 end
    return out
end

-- -- the tab -------------------------------------------------------------------------------------

T.test("Chat World: a World tab after the chat tabs, on by default, with the Discord mark", function()
    local A = chat()
    local C = A.CPChat
    T.ok(C:InWorld(), "the server put us in World at login")
    T.ok(C:Get("worldTab")); T.ok(C:Get("discord")); T.ok(C:Get("worldJoin"))
    local t = A.CPChatWorldTab
    T.shown(t, "World tab")
    T.eq(A.CPChatWorldTabText:GetText(), "World")
    local _, rel = t:GetPoint(1)
    T.eq(rel, A.ChatFrame2Tab, "right after the last docked tab")
    T.shown(A.CPChatWorldTabDiscord, "Discord mark on the tab")
    T.has(A.CPChatWorldTabDiscord:GetTexture(), "Chat_Discord", "generated art")
    T.eq(t.cpLine:GetAlpha(), 0, "not selected")
    setting(A, "discord", false)
    T.hidden(A.CPChatWorldTabDiscord, "no mark while Discord lines are hidden")
    -- the settings window lists the three switches
    local labels = {}
    for _, o in ipairs(A.WenillaCore.schemas.Chat.options) do labels[o.key] = o.label end
    T.eq(labels.worldTab, "World tab"); T.eq(labels.discord, "Show Discord messages"); T.eq(labels.worldJoin, "Join World chat")
end)

T.test("Chat World: World lines from both sides land in the tab, [W] in the other windows", function()
    local A, B = pair()
    B.SendChatMessage("LF healer for SM", "CHANNEL", nil, B.GetChannelName("World")); api.pump(A)
    T.has(seen(lastWorld(A)), "[Berra]: LF healer for SM")
    T.has(lastWorld(A), "|Hplayer:Berra|h", "clickable name")
    T.eq(A.CPChatWorldTab.cpDot:GetAlpha(), 1, "unread dot")
    T.eq(lastMain(A), "[W] [Berra]: LF healer for SM", "short name in the main window")
    api.click(A.CPChatWorldTab)
    T.shown(A.CPChatWorldFrame)
    T.hidden(A.ChatFrame1, "main window put away while reading World")
    T.eq(A.CPChatWorldTab.cpLine:GetAlpha(), 1, "selected")
    T.eq(A.CPChatWorldTab.cpDot:GetAlpha(), 0, "read")
    T.eq(A.ChatFrame1Tab.cpLine:GetAlpha(), 0)
    local msgs = api.state(A.CPChatWorldFrame).messages
    T.has(seen(msgs[#msgs]), "[Berra]: LF healer for SM")
    -- copy takes the World lines
    local text = A.CPChat:CopyText()
    T.has(text, "[Berra]: LF healer for SM")
    -- back to General with its tab
    api.click(A.ChatFrame1Tab)
    T.hidden(A.CPChatWorldFrame)
    T.shown(A.ChatFrame1)
    -- a whisper tab and the World tab take turns
    setting(A, "whisperTabs", true)
    B.SendChatMessage("psst", "WHISPER", nil, "Herald"); api.pump(A)
    api.click(A.CPChatWorldTab)
    api.click(A.CPChatWhisperTab1)
    T.hidden(A.CPChatWorldFrame, "the whisper replaces World")
    T.shown(A.CPChatWhisperFrame)
    api.click(A.CPChatWorldTab)
    T.hidden(A.CPChatWhisperFrame)
    T.shown(A.CPChatWorldFrame)
    api.click(A.ChatFrame1Tab)
    T.shown(A.ChatFrame1, "General is back after both")
end)

T.test("Chat World: your name in World is highlighted and marks the tab", function()
    local A, B = pair()
    B.SendChatMessage("Herald, want to group?", "CHANNEL", nil, B.GetChannelName("World")); api.pump(A)
    T.has(lastWorld(A), "|cffff9e2eHerald|r")
    T.eq(A.CPChatWorldTab.cpDot:GetAlpha(), 1)
    local r, g = unpack(api.state(A.CPChatWorldTab.cpDot).vertex or { 1, 0.62 })
    T.near(g, 0.62, 0.02, "orange mention dot")
end)

-- -- Discord -------------------------------------------------------------------------------------

T.test("Chat World: Discord lines show as [D] Name: text in Discord blue", function()
    local A, B = pair()
    local n = api.world_discord(A, "Anna_B", "hi all :wave:")
    T.eq(n, 2, "both clients in World got it")
    T.has(lastWorld(A), "|cff7289da[D]|r Anna_B: hi all :wave:")
    T.eq(api.visible(lastWorld(A)), "[D] Anna_B: hi all :wave:")
    T.has(api.visible(lastWorld(B)), "[D] Anna_B: hi all :wave:", "the full suite too")
    -- escape characters cannot sneak in
    api.world_discord(A, "Mal|cffff0000", "x |Hitem:1|h[Fake]|h")
    T.lacks(lastWorld(A), "|cffff0000", "no colour from a name")
    T.lacks(lastWorld(A), "|Hitem", "no links from Discord")
    -- the player's ignore list hides a Discord name
    table.insert(A.__ignores, "Troll")
    local before = #worldLines(A)
    api.world_discord(A, "troll", "spam")
    T.eq(#worldLines(A), before, "ignored")
    -- "Show Discord messages" off
    setting(A, "discord", false)
    api.world_discord(A, "Anna_B", "anyone?")
    T.eq(#worldLines(A), before, "hidden")
    T.lacks(lastMain(A), "anyone?")
end)

T.test("Chat World: Discord lines for the guild's linked channel show in guild colour", function()
    local A = chat()
    setting(A, "timestamps", "off")
    api.world_discord(A, "Officer", "raid at 8", "G")
    T.eq(lastMain(A), "[G] [D] Officer: raid at 8")
    T.lacks(api.visible(lastWorld(A) or ""), "raid at 8", "not in World")
end)

T.test("Chat World: hiding the tab puts World and [D] lines in the main window", function()
    local A, B = pair()
    api.click(A.CPChatWorldTab)
    api.click(A.CPChatWorldTab, "RightButton")
    T.no(A.CPChat:Get("worldTab"), "setting off")
    T.hidden(A.CPChatWorldTab)
    T.hidden(A.CPChatWorldFrame, "left the World view")
    T.shown(A.ChatFrame1)
    T.has(api.chat_text(A), "World tab hidden")
    T.eq(A.__chat_channels.World, A.ChatFrame1, "World added to the main window's channels")
    api.world_discord(A, "Anna_B", "still here")
    T.eq(lastMain(A), "[W] [D] Anna_B: still here")
    setting(A, "channelNames", "full")
    api.world_discord(A, "Anna_B", "full names")
    T.eq(lastMain(A), "[" .. A.GetChannelName("World") .. ". World] [D] Anna_B: full names")
    -- /cpchat world brings it back, and the main window gives World back to the tab
    api.slash(A, "/cpchat world")
    T.ok(A.CPChat:Get("worldTab"))
    T.shown(A.CPChatWorldTab)
    T.eq(A.__chat_channels.World, nil)
end)

T.test("Chat World: the addon switched off prints Discord lines plainly", function()
    local A = chat()
    A.WenillaCore:SetAddonEnabled("Chat", false)
    T.hidden(A.CPChatWorldTab)
    api.world_discord(A, "Anna_B", "plain")
    T.eq(lastMain(A), "[World] [D] Anna_B: plain")
end)

-- -- talking in World ----------------------------------------------------------------------------

T.test("Chat World: Enter in the World tab and /world both talk in World", function()
    local A, B = pair()
    local id = A.GetChannelName("World")
    api.click(A.CPChatWorldTab)
    A.ChatFrame_OpenChat("")
    T.eq(A.ChatFrameEditBox.chatType, "CHANNEL")
    T.eq(A.ChatFrameEditBox.channelTarget, id)
    api.slash(A, "/world anyone up for Gnomeregan?"); api.pump(B)
    T.has(seen(lastWorld(B)), "[Herald]: anyone up for Gnomeregan?")
    T.has(seen(lastWorld(A)), "[Herald]: anyone up for Gnomeregan?", "and in your own tab")
    api.slash(A, "/world " .. string.rep("a", 300)); api.pump(B)
    T.eq(string.len(B.CPChat.world.lines[#B.CPChat.world.lines].text) < 400, true, "cut to 255")
    -- out of World: a hint instead of a line
    A.LeaveChannelByName("World")
    local n = #worldLines(B)
    api.slash(A, "/world hello?"); api.pump(B)
    T.eq(#worldLines(B), n)
    T.has(api.chat_text(A), "You are not in World chat")
end)

T.test("Chat World: Tab in an empty input line cycles Say, Guild, World", function()
    local A = chat()
    local eb = A.ChatFrameEditBox
    local tab = eb:GetScript("OnTabPressed")
    T.ok(tab, "Tab hooked")
    local id = A.GetChannelName("World")
    eb.chatType = "SAY"
    eb:SetText("")
    tab()
    T.eq(eb.chatType, "GUILD")
    tab()
    T.eq(eb.chatType, "CHANNEL"); T.eq(eb.channelTarget, id)
    T.eq(A.ChatFrameEditBoxHeader:GetText(), "CHANNEL" .. id .. ":")
    tab()
    T.eq(eb.chatType, "SAY", "round again")
    A.IsShiftKeyDown = function() return 1 end
    tab()
    T.eq(eb.chatType, "CHANNEL", "Shift+Tab goes back")
    A.IsShiftKeyDown = function() return nil end
    -- not while typing, not for whispers
    eb:SetText("half a line")
    tab()
    T.eq(eb.chatType, "CHANNEL")
    eb:SetText("")
    eb.chatType = "WHISPER"
    tab()
    T.eq(eb.chatType, "WHISPER")
    -- out of World: World leaves the cycle
    A.LeaveChannelByName("World")
    eb.chatType = "GUILD"
    tab()
    T.eq(eb.chatType, "SAY")
end)

-- -- Join World chat -----------------------------------------------------------------------------

T.test("Chat World: \"Join World chat\" off leaves World and stays off; on joins again", function()
    local A = chat()
    api.tick(A, 9)                                    -- the login settles
    T.eq(sent(A)["worldoff"], nil, "nothing to do while the setting matches")
    setting(A, "worldJoin", false)
    api.pump(A)
    T.eq(sent(A)["worldoff"], 1, ".wnl worldoff")
    T.no(A.CPChat:InWorld(), "left World")
    T.no(A.CPChat:Get("worldJoin"))
    -- a relog: the server remembers (openvanilla_world_pref), nothing is sent again
    api.tick(A, 6)
    setting(A, "opacity", 90)
    T.eq(sent(A)["worldoff"], 1)
    setting(A, "worldJoin", true)
    api.pump(A)
    T.eq(sent(A)["worldon"], 1, ".wnl worldon")
    T.ok(A.CPChat:InWorld(), "back in World")
end)

T.test("Chat World: a character the server keeps out of World is put back when the setting is on", function()
    local A = chat(nil, { off = true })
    T.no(A.CPChat:InWorld(), "switched off on another computer")
    api.tick(A, 9)
    T.eq(sent(A)["worldon"], 1, "reconciled once the login settled")
    T.ok(A.CPChat:InWorld())
end)

T.test("Chat World: .wnl worldoff typed by hand turns the setting off (WO 0)", function()
    local A = chat()
    api.tick(A, 9)
    A.SendChatMessage(".wnl worldoff", "SAY")
    api.pump(A)
    T.no(A.CPChat:Get("worldJoin"), "the server's word wins")
    api.tick(A, 6)
    T.eq(sent(A)["worldon"], nil, "and is not fought")
end)
