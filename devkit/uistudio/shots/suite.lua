-- UI Studio shots: the Open Vanilla windows players see most, each set up the way the addon tests
-- set them up. A shot returns (env, the window to draw [, extra objects]). Add your own shots
-- files to devkit/uistudio/shots/ (see devkit/sim/render/README.md for the format).
local S, api = ...
local T = S.T

local function chatPieces(env)
    local cf = env.ChatFrame1
    env.CreateFrame("Button", "ChatFrameMenuButton", env.UIParent)
    for i = 1, 2 do
        local f = env["ChatFrame" .. i]
        for _, b in ipairs({ "UpButton", "DownButton", "BottomButton" }) do env.CreateFrame("Button", "ChatFrame" .. i .. b, f) end
        f:CreateTexture("ChatFrame" .. i .. "Background", "BACKGROUND"):SetTexture(0, 0, 0, 0.25)
        local tab = env["ChatFrame" .. i .. "Tab"]
        for _, n in ipairs({ "Left", "Middle", "Right", "Flash" }) do tab:CreateTexture("ChatFrame" .. i .. "Tab" .. n, "BACKGROUND") end
        tab:CreateFontString("ChatFrame" .. i .. "TabText", "OVERLAY"):SetText(i == 1 and "General" or "Combat Log")
        tab:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 2 + (i - 1) * 70, -4)
        tab:SetHeight(32); tab:SetWidth(64)
    end
    cf.isDocked, env.ChatFrame2.isDocked = 1, 1
    env.DOCKED_CHAT_FRAMES = { cf, env.ChatFrame2 }
    env.SELECTED_DOCK_FRAME = cf
    local eb = env.ChatFrameEditBox
    eb:SetPoint("TOPLEFT", cf, "BOTTOMLEFT", -5, -2)
    eb:SetHeight(32)
    for _, n in ipairs({ "Left", "Right", "Mid" }) do eb:CreateTexture("ChatFrameEditBox" .. n, "BACKGROUND") end
    eb:CreateFontString("ChatFrameEditBoxHeader", "OVERLAY")
    env.ChatTypeInfo = { SAY = { r = 1, g = 1, b = 1 }, GUILD = { r = 0.25, g = 1, b = 0.25 }, WHISPER = { r = 1, g = 0.5, b = 1 },
        PARTY = { r = 0.67, g = 0.67, b = 1 }, CHANNEL = { r = 1, g = 0.75, b = 0.75 } }
    env.FCF_FlashTab = function() end
    env.FCF_DockUpdate = function() end
    env.ChatEdit_UpdateHeader = function(box) env.ChatFrameEditBoxHeader:SetText((box.chatType or "SAY") .. ":") end
end

S.shot("bug_report", function()
    local env = T.addon("WenillaCore")
    env.WenillaCore.Bugs.Open()
    api.type(env.WenillaCore_BugNote, "The innkeeper in Goldshire walks through the wall.")
    return env, env.WenillaCore_BugFrame
end)

S.shot("welcome", function()
    local env = T.addon("WenillaCore")
    env.__slash("/welcome")
    local f = env.WenillaCore.Welcome and env.WenillaCore.Welcome.frame or rawget(env, "WenillaCore_Welcome")
    return env, f
end)

S.shot("loot_window", function()
    local env = T.addon("Loot", { latency = false, lootEngine = true })
    api.open_loot(env, { { coin = 31204 }, { 2589, 5 }, { 1203, 1 }, { 2770, 2 } }, { shift = true })
    api.pump(env)
    return env, env.Loot_Frame
end)

S.shot("loot_recap", function()
    local env = T.addon("Loot", { latency = false, lootEngine = true })
    api.connect(env)
    api.server_packet(env, "AL", "3,31204;2,2")
    api.open_loot(env, { { coin = 31204 }, { 2589, 5 }, { 1203, 1 }, { 2770, 2 } })
    api.pump(env)
    return env, env.Loot_Recap
end)

S.shot("chat_expanded", function()
    local env = T.client({ name = "Herald", class = "HUNTER" })
    chatPieces(env)
    api.load_with_deps(env, "Chat")
    api.login(env)
    for i = 1, 40 do env.ChatFrame1:AddMessage("|cffffd100[Herald]|r line " .. i .. " of a busy evening in Goldshire") end
    env.CPChat:OpenExpanded()
    return env, env.CPChatExpanded
end)

S.shot("chat_window", function()
    local env = T.client({ name = "Herald", class = "HUNTER" })
    chatPieces(env)
    api.load_with_deps(env, "Chat")
    api.login(env)
    for i = 1, 12 do env.ChatFrame1:AddMessage("|cff40ff40[Guild] Anna:|r anyone up for Deadmines? " .. i) end
    return env, env.ChatFrame1, { env.CPChatBar }
end)
