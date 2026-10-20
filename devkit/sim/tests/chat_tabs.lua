-- Chat: the tab strip. Docked tabs, the World tab, the Guilds addon's Guild tab and whisper tabs
-- share one row on the chat panel; nothing may cover another tab or spill past the panel, however
-- many tabs there are ("people are losing tabs"). The sim tracks anchors, not positions, so this
-- file resolves the anchor chains itself.
local T, api = ...

local function stockPieces(env, n)
    env.CreateFrame("Button", "ChatFrameMenuButton", env.UIParent)
    local names = { "General", "Combat Log", "Trade and Looking for Group", "Loot", "Guild and Officer", "Raid", "Spam" }
    env.DOCKED_CHAT_FRAMES = {}
    for i = 1, n do
        local f = env["ChatFrame" .. i]
        for _, b in ipairs({ "UpButton", "DownButton", "BottomButton" }) do env.CreateFrame("Button", "ChatFrame" .. i .. b, f) end
        local tab = env["ChatFrame" .. i .. "Tab"]
        for _, p in ipairs({ "Left", "Middle", "Right", "Flash" }) do tab:CreateTexture("ChatFrame" .. i .. "Tab" .. p, "BACKGROUND") end
        tab:CreateFontString("ChatFrame" .. i .. "TabText", "OVERLAY"):SetText(names[i])
        tab:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 2 + (i - 1) * 70, -4)
        tab:SetHeight(32)
        tab:SetWidth(64)
        tab:Show()
        f.isDocked = 1
        table.insert(env.DOCKED_CHAT_FRAMES, f)
    end
    env.SELECTED_DOCK_FRAME = env.ChatFrame1
    local eb = env.ChatFrameEditBox
    eb:SetPoint("TOPLEFT", env.ChatFrame1, "BOTTOMLEFT", -5, -2)
    eb:SetHeight(32)
    eb:CreateFontString("ChatFrameEditBoxHeader", "OVERLAY")
    env.ChatTypeInfo = { SAY = { r = 1, g = 1, b = 1 }, WHISPER = { r = 1, g = 0.5, b = 1 }, CHANNEL = { r = 1, g = 0.75, b = 0.75 } }
    env.ChatEdit_UpdateHeader = function(box) env.ChatFrameEditBoxHeader:SetText((box.chatType or "SAY") .. ":") end
    env.ChatFrame_AddChannel = function() end
    env.ChatFrame_RemoveChannel = function() end
end

local function client(docked, width)
    local env = T.client({ name = "Herald", class = "HUNTER", guild = { name = "Ashen Vanguard", members = 12 } })
    stockPieces(env, docked)
    if width then env.ChatFrame1:SetWidth(width) end
    api.load_with_deps(env, "Chat")
    api.load_with_deps(env, "Guilds")
    api.login(env)
    api.connect(env)
    api.world_server(env)
    env.ClassicPlus_Manager:SetSetting("Chat", "whisperTabs", true)
    api.tick(env, 1)
    return env
end

-- Resolve a region's rectangle (left, bottom, right, top) from its anchors, as the client would.
local function rect(env, f, depth)
    depth = (depth or 0) + 1
    if depth > 40 then error("anchor loop") end
    local s = api.state(f)
    if f == env.UIParent then return 0, 0, 1024, 768 end
    local pts = s.points or {}
    if #pts == 0 then
        local l, w, top, h = s.left or 0, s.w or 0, s.top or 768, s.h or 0
        return l, top - h, l + w, top
    end
    local function px(rel, rp)
        local l, b, r, t = rect(env, rel or env.UIParent, depth)
        local x = string.find(rp, "LEFT") and l or (string.find(rp, "RIGHT") and r or (l + r) / 2)
        local y = string.find(rp, "BOTTOM") and b or (string.find(rp, "TOP") and t or (b + t) / 2)
        return x, y
    end
    local L, R, B, Tp
    for _, p in ipairs(pts) do
        local x, y = px(p[2], p[3])
        x, y = x + (p[4] or 0), y + (p[5] or 0)
        if string.find(p[1], "LEFT") then L = x elseif string.find(p[1], "RIGHT") then R = x end
        if string.find(p[1], "BOTTOM") then B = y elseif string.find(p[1], "TOP") then Tp = y end
        if p[1] == "CENTER" then L = x - (s.w or 0) / 2; B = y - (s.h or 0) / 2 end
    end
    local w, h = s.w or 0, s.h or 0
    if L and not R then R = L + w elseif R and not L then L = R - w elseif not L then L, R = 0, w end
    if B and not Tp then Tp = B + h elseif Tp and not B then B = Tp - h elseif not B then B, Tp = 0, h end
    return L, B, R, Tp
end

local function visibleTabs(env)
    local out = {}
    local function add(t, label)
        if t and t:IsShown() and (t:GetAlpha() or 1) > 0 then table.insert(out, { t = t, label = label }) end
    end
    for i = 1, 7 do
        local tab = env["ChatFrame" .. i .. "Tab"]
        if tab and tab.cpOrig and env.ChatFrame1 and env["ChatFrame" .. i].isDocked then add(tab, "ChatFrame" .. i .. "Tab") end
    end
    add(env.CPChatWorldTab, "World")
    add(env.ChatFrame_GuildTab, "Guild")
    for i = 1, 6 do add(env["CPChatWhisperTab" .. i], "Whisper" .. i) end
    return out
end

local function checkStrip(env, why)
    local tabs = visibleTabs(env)
    local bl, _, br = rect(env, env.CPChatBar)
    local buttonsLeft = rect(env, env.CPChatExpandButton)
    for _, a in ipairs(tabs) do
        local l, b, r, t = rect(env, a.t)
        a.l, a.b, a.r, a.t2 = l, b, r, t
        T.ok(r - l >= 30, why .. ": " .. a.label .. " is too narrow to click (" .. (r - l) .. ")")
        T.ok(l >= bl - 0.5, why .. ": " .. a.label .. " starts left of the panel")
        T.ok(r <= br + 0.5, why .. ": " .. a.label .. " runs past the panel's right edge")
        -- the first row shares the bar with the menu, copy and expand buttons
        if b < (select(2, rect(env, env.CPChatBar))) + 1 then
            T.ok(r <= buttonsLeft + 0.5, why .. ": " .. a.label .. " covers the chat buttons")
        end
    end
    for i = 1, #tabs do
        for j = i + 1, #tabs do
            local a, c = tabs[i], tabs[j]
            local overlap = a.l < c.r - 0.5 and c.l < a.r - 0.5 and a.b < c.t2 - 0.5 and c.b < a.t2 - 0.5
            T.ok(not overlap, why .. ": " .. a.label .. " and " .. c.label .. " overlap")
        end
    end
    return tabs
end

local function whisper(env, name) env.CPChat:RouteWhisper(name, "[" .. name .. "] whispers: hi", 1, 0.5, 1, "CHAT_MSG_WHISPER", "hi") end

T.test("Chat tabs: General, Combat Log, World and Guild sit side by side", function()
    local A = client(2)
    local tabs = checkStrip(A, "two docked")
    T.eq(#tabs, 4, "General, Combat Log, World, Guild")
end)

T.test("Chat tabs: whisper tabs never cover the docked, World or Guild tabs", function()
    local A = client(2)
    for _, n in ipairs({ "Berra", "Aldricthegreat", "Mirelle", "Thornwhistle", "Ka" }) do whisper(A, n) end
    api.tick(A, 0.5)
    local tabs = checkStrip(A, "five whispers")
    T.eq(#tabs, 9)
end)

T.test("Chat tabs: many docked tabs on a narrow chat fold into rows instead of spilling off", function()
    local A = client(7, 320)
    for _, n in ipairs({ "Berra", "Aldricthegreat", "Mirelle", "Thornwhistle", "Ka", "Zed" }) do whisper(A, n) end
    api.tick(A, 0.5)
    local tabs = checkStrip(A, "seven docked, six whispers, 320 px")
    T.eq(#tabs, 15, "every tab still shown")
end)

T.test("Chat tabs: resizing the chat lays the tabs out again", function()
    local A = client(5)
    whisper(A, "Berra")
    api.tick(A, 0.5)
    checkStrip(A, "wide")
    A.ChatFrame1:SetWidth(300)
    api.tick(A, 0.5)
    checkStrip(A, "after shrinking to 300 px")
end)

T.test("Chat tabs: the Guild tab follows the strip, and comes back from the chat menu", function()
    local A = client(2)
    T.shown(A.ChatFrame_GuildTab)
    A.ClassicPlus_Manager:SetSetting("Guilds", "showChatTab", false)
    api.tick(A, 0.5)
    T.hidden(A.ChatFrame_GuildTab)
    checkStrip(A, "guild tab hidden")
    local m = A.CPChat:OpenMenu(A.CPChatMenuButton)
    T.ok(m, "chat menu opens")
    api.click_text(A, "Show the Guild tab")
    api.tick(A, 0.5)
    T.shown(A.ChatFrame_GuildTab)
    checkStrip(A, "guild tab back")
end)

T.test("Chat tabs: the World tab comes back from the chat menu too", function()
    local A = client(2)
    A.ClassicPlus_Manager:SetSetting("Chat", "worldTab", false)
    api.tick(A, 0.5)
    T.ok(not (A.CPChatWorldTab and A.CPChatWorldTab:IsShown()), "hidden")
    A.CPChat:OpenMenu(A.CPChatMenuButton)
    api.click_text(A, "Show the World tab")
    api.tick(A, 0.5)
    T.shown(A.CPChatWorldTab)
    checkStrip(A, "world tab back")
end)

T.test("Chat tabs: turning Chat off gives the Guild tab back its own place", function()
    local A = client(2)
    A.WenillaCore:SetAddonEnabled("Chat", false)
    api.tick(A, 1)
    T.shown(A.ChatFrame_GuildTab)
    local p, rel = A.ChatFrame_GuildTab:GetPoint(1)
    T.ok(rel ~= A.CPChatBar, "not left on Chat's bar")
end)
