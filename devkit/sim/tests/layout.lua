-- WenillaCore's layout layer (UI Studio): Layout.lua's theme, frame overrides by path, tunables, art swaps.
local T, api = ...

T.test("Layout: the theme changes the window colours, the title and every UI.Font size", function()
    local env = T.client({ name = "Herald", class = "HUNTER" })
    api.load_with_deps(env, "WenillaCore")
    local UI = env.WenillaCore.UI
    UI.ApplyTheme({ WINDOW_BG = { 0.2, 0.1, 0.05, 0.9 }, TITLE_TEXT = { 1, 0.5, 0 }, TITLE_SIZE = 13, FONT_SCALE = 1.5, MUTED = { 0.3, 0.3, 0.3 } })
    local f = UI.Window("LayoutTestWin", { width = 200, height = 100, title = "Hi" })
    local bg = api.state(f).backdropColor
    T.eq(bg[1], 0.2); T.eq(bg[3], 0.05)
    local tc = api.state(f.title).textColor
    T.eq(tc[1], 1); T.eq(tc[2], 0.5)
    T.eq(api.state(f.title).fontPath[2], 19.5, "13 x 1.5")
    T.eq(UI.MUTED[1], 0.3, "colour tokens change in place")
end)

T.test("Layout: frame overrides by path move, size, recolour and hide windows and their pieces", function()
    local env = T.client({ name = "Herald", class = "HUNTER" })
    api.load_with_deps(env, "WenillaCore")
    env.WenillaCore_Layout = { frames = {
        LayoutTestWin = { point = { "TOPLEFT", "UIParent", "TOPLEFT", 40, -60 }, w = 300, scale = 1.2, alpha = 0.8 },
        ["LayoutTestWin.title"] = { color = { 0, 1, 0 }, fontSize = 15 },
        ["LayoutTestWin.titleBar"] = { fill = { 0.5, 0, 0, 1 } },
        ["LayoutTestWin.closeButton"] = { hide = true },
    } }
    local UI = env.WenillaCore.UI
    local f = UI.Window("LayoutTestWin", { width = 200, height = 100, title = "Hi" })
    f:Show()
    local s = api.state(f)
    T.eq(s.w, 300); T.eq(s.scale, 1.2); T.eq(s.alpha, 0.8)
    local p = s.points[1]
    T.eq(p[1], "TOPLEFT"); T.eq(p[4], 40); T.eq(p[5], -60)
    api.tick(env, 1)                                   -- the pieces are applied as soon as they exist
    T.eq(api.state(f.title).textColor[2], 1)
    T.eq(api.state(f.title).fontPath[2], 15)
    T.eq(api.state(f.titleBar).color[1], 0.5)
    T.no(f.closeButton:IsShown(), "hidden")
    T.eq(env.WenillaCore.LayoutKit.Resolve("LayoutTestWin.title"), f.title)
    T.eq(env.WenillaCore.LayoutKit.Resolve("NoSuchFrame.x"), nil)
end)

T.test("Layout: a dragged position still wins over the studio's", function()
    local env = T.client({ name = "Herald", class = "HUNTER" })
    api.load_with_deps(env, "WenillaCore")
    api.login(env)
    env.WenillaCore_Config.positions = env.WenillaCore_Config.positions or {}
    env.WenillaCore_Config.positions.LayoutTestWin2 = { x = 500, y = 400 }
    env.WenillaCore_Layout = { frames = { LayoutTestWin2 = { point = { "CENTER", "UIParent", "CENTER", 0, 0 } } } }
    local f = env.WenillaCore.UI.Window("LayoutTestWin2", { width = 200, height = 100 })
    local p = api.state(f).points[1]
    T.eq(p[1], "TOPLEFT"); T.eq(p[4], 500); T.eq(p[5], 400)
end)

T.test("Layout: W:Tune returns the studio's number, else the default; W:Art swaps art names", function()
    local env = T.client({ name = "Herald", class = "HUNTER" })
    api.load_with_deps(env, "WenillaCore")
    local W = env.WenillaCore
    T.eq(W:Tune("Test.knob", 5), 5)
    env.WenillaCore_Layout = { tune = { ["Test.knob"] = 9, ["Test.wrongType"] = "x" }, art = { Chat_Menu = "Chat_Copy" } }
    T.eq(W:Tune("Test.knob", 5), 9)
    T.eq(W:Tune("Test.wrongType", 3), 3, "a value of the wrong type is ignored")
    T.eq(W.tunables["Test.knob"], 5, "every knob is listed with its default")
    local f = env.CreateFrame("Frame", nil, env.UIParent)
    local t = f:CreateTexture()
    W:Art(t, "Chat_Menu")
    T.has(tostring(api.state(t).texture), "Chat_Copy", "the swapped art is used")
end)

T.test("Layout: a window's look is applied after its addon builds it; art, font and studio backdrops", function()
    local env = T.client({ name = "Herald", class = "HUNTER" })
    api.load_with_deps(env, "WenillaCore")
    api.login(env)
    env.WenillaCore_Layout = { frames = {
        LayoutTestWin3 = { point = { "CENTER", "UIParent", "CENTER", 10, 20 }, bg = { 0.5, 0, 0, 1 },
            backdrop = { bg = "Studio_Bg", edge = "Studio_Edge", edgeSize = 12, insets = 3 } },
        ["LayoutTestWin3.title"] = { font = "Fonts\\ARIALN.TTF" },
        ["LayoutTestWin3.icon"] = { art = "Chat_Copy" },
    } }
    local f = env.WenillaCore.UI.Window("LayoutTestWin3", { width = 200, height = 100, title = "Hi" })
    f:SetBackdropColor(0, 0, 0, 1)                     -- the addon colours its window after UI.Window
    f.icon = f.icon or f:CreateTexture(nil, "ARTWORK")
    f:Show()
    api.tick(env, 1)
    local s = api.state(f)
    T.eq(s.backdropColor[1], 0.5, "the studio's face colour wins over the addon's own")
    T.eq(s.backdrop.edgeSize, 12)
    T.has(s.backdrop.edgeFile, "Studio_Edge")
    T.eq(s.points[1][4], 10, "still where the studio put it")
    T.eq(api.state(f.title).fontPath[1], "Fonts\\ARIALN.TTF")
    T.has(tostring(api.state(f.icon).texture), "Chat_Copy")
end)

T.test("Layout: a frame moved with /move keeps the player's spot", function()
    local env = T.client({ name = "Herald", class = "HUNTER" })
    api.load_with_deps(env, "WenillaCore")
    api.login(env)
    env.ClassicPlus_UI = { pos = { LayoutTestStock = { left = 50, top = 600 } } }
    local f = env.CreateFrame("Frame", "LayoutTestStock", env.UIParent)
    f:SetPoint("TOPLEFT", env.UIParent, "BOTTOMLEFT", 50, 600)
    env.WenillaCore_Layout = { frames = { LayoutTestStock = { point = { "CENTER", "UIParent", "CENTER", 0, 0 }, alpha = 0.5 } } }
    api.tick(env, 1)
    local s = api.state(f)
    T.eq(s.points[1][4], 50, "the player's /move position stays")
    T.eq(s.alpha, 0.5, "the rest of the entry still applies")
end)

T.test("Layout: a button's own label is reachable as <button>.@text", function()
    local env = T.client({ name = "Herald", class = "HUNTER" })
    api.load_with_deps(env, "WenillaCore")
    local b = env.CreateFrame("Button", "LayoutTestButton", env.UIParent)
    b:SetText("Send")
    env.WenillaCore_Layout = { frames = { ["LayoutTestButton.@text"] = { color = { 0, 1, 0, 1 } } } }
    api.tick(env, 1)
    T.eq(env.WenillaCore.LayoutKit.Resolve("LayoutTestButton.@text"), b:GetFontString())
    T.eq(api.state(b:GetFontString()).textColor[2], 1)
end)
