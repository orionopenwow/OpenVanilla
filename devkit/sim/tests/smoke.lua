-- Suite-wide smoke tests: everything loads, every slash command runs, the demo stream, the
-- /addons manager and Pure Vanilla mode, all with zero Lua errors.
local T, api = ...

local ARGS = { "", "help", "status", "on", "off", "reset", "list", "edit", "ic", "ooc", "lfrp", "st",
    "bank", "check", "ready", "pull", "pull 5", "12", "cancel", "heal", "dmg", "text", "accept", "loot",
    "camera", "debug", "menu", "Somebody", "  spaced  args  " }

T.test("smoke: Lua 5.0 guard is clean on every addon file", function()
    local root = api.repo .. "/Data/Interface/AddOns"
    local issues, n = {}, 0
    for _, dir in ipairs(api.list_dir(root)) do
        if not string.match(string.lower(dir), "^blizzard_") then
            for _, f in ipairs(api.list_dir(root .. "/" .. dir)) do
                if string.match(f, "%.lua$") then
                    n = n + 1
                    for _, it in ipairs(api.guard.scan_file(root .. "/" .. dir .. "/" .. f)) do
                        table.insert(issues, dir .. "/" .. f .. ":" .. it.line .. ": " .. it.msg)
                    end
                end
            end
        end
    end
    T.ok(n >= 17, "expected the suite's .lua files, found " .. n)
    T.eq(table.concat(issues, "\n"), "", "Lua 5.1-only syntax")
end)

T.test("smoke: guard catches 5.1-only syntax", function()
    local src = "local n = #t\nlocal m = 5 % 2\nlocal a = select(2, x)\nfor w in string.gmatch(s, '.') do end\n"
        .. "function f() return ... end\nlocal s = '#%' -- # % select(\n"
    local lines = {}
    for _, it in ipairs(api.guard.scan(src)) do table.insert(lines, it.line) end
    T.eq(table.concat(lines, ","), "1,2,3,4,5")
end)

T.test("smoke: whole suite loads in toc order and logs in", function()
    local env = T.suite()
    local order = env.__addon_order
    T.eq(order[1], "!Compat_112")
    T.eq(order[2], "WenillaCore")
    -- every suite folder in the repo (a .toc with "## X-ClassicPlus", plus !Compat_112) loads
    T.ok(#order >= 13, "addon count: " .. table.concat(order, " "))
    T.eq(#order, #api.suite_names(env), "every addon folder loads: " .. table.concat(order, " "))
    for _, id in ipairs(env.WenillaCore.ADDONS) do
        T.ok(env.WenillaCore.refreshers[id], id .. " registered a refresher with WenillaCore")
    end
    api.tick(env, 5)
    T.has(api.chat_text(env), "native suite loaded")
end)

T.test("smoke: no two addons claim the same slash command", function()
    local env = T.suite()
    local owner, dup = {}, {}
    for _, c in ipairs(api.slash_commands(env)) do
        for _, cmd in ipairs(c.commands) do
            local k = string.lower(cmd)
            if owner[k] and owner[k] ~= c.key then table.insert(dup, cmd .. " (" .. owner[k] .. ", " .. c.key .. ")") end
            owner[k] = c.key
        end
    end
    T.eq(table.concat(dup, "; "), "")
end)

T.test("smoke: every slash command, bare and with common arguments", function()
    local env = T.suite({ guild = { name = "Ashen Vanguard", members = 12 }, party = { { name = "Brakkus", class = "WARRIOR" } } })
    api.tick(env, 7)
    local cmds = api.slash_commands(env)
    T.ok(#cmds >= 15, "slash keys found: " .. #cmds)
    for _, c in ipairs(cmds) do
        for _, alias in ipairs(c.commands) do
            T.ok(env.__slash(alias), alias .. " did not dispatch")
            api.tick(env, 0.2)
        end
        for _, a in ipairs(ARGS) do
            env.__slash(c.commands[1] .. " " .. a)
            api.tick(env, 0.2)
        end
    end
    -- leave Pure Vanilla if a toggle left it on, then make sure everything still works
    if env.WenillaCore.isVanillaMode then env.__slash("/vanilla") end
    api.tick(env, 3)
    T.no(env.WenillaCore.isVanillaMode)
end)

T.test("smoke: demo stream drives every window for 10 s", function()
    local env = T.suite({ bags = { [0] = { size = 16, items = { { 2589, 20 }, { 4306, 3 }, { 7073, 2 } } } } })
    api.set_target(env, { name = "Onyxia", hostile = true, level = -1 })
    env.__slash("/wnl demo")
    T.ok(env.WenillaCore.demoRunning)
    api.tick(env, 10)
    T.shown(env.Chronicle_Frame, "Chronicle")
    T.ok(api.screen_has(env, "Ilyndra", env.Chronicle_Frame), "Chronicle lists the demo roster")
    T.shown(env.Vanguard_Frame, "Vanguard")
    local top = env.Vanguard_Bar1.left:GetText()
    T.ok(top == "Brakkus" or top == "Ilyndra", "Vanguard top threat is the demo tank or mage, got " .. tostring(top))
    T.ok(env.Compass.pins[1], "Compass got demo pins")
    local n = 0
    for _ in pairs(env.Concord.listings) do n = n + 1 end
    T.eq(n, 5, "Concord demo listings")
    T.ok(env.Ledger.prices[2589], "Ledger got demo prices for bag items")
    T.ok(env.Visage_DemoAnchor:IsShown(), "Visage demo plate")
    T.ok(env.Castline.casts.Onyxia or env.Castline.ending, "Castline saw a demo cast")
    -- Persona follows the suite's demo switch on its next housekeeping tick
    env.Persona.ShowList()
    api.tick(env, 1.5)
    T.has(env.PersonaFrame.list.info:GetText(), "4 profiles")
    env.__slash("/wnl demo")
    T.no(env.WenillaCore.demoRunning)
    api.tick(env, 1.5)
    T.hidden(env.Vanguard_Frame, "Vanguard after demo off")
    T.no(env.Visage_DemoAnchor:IsShown(), "demo plate hidden")
    T.eq(next(env.Ledger.prices), nil, "Ledger demo prices cleared")
    T.has(env.PersonaFrame.list.info:GetText(), "0 profiles")
end)

T.test("smoke: /addons manager toggles every addon off and on", function()
    local env = T.suite()
    env.__slash("/wnl demo")
    api.tick(env, 2)
    env.__slash("/addons")
    local win = env.ClassicPlus_SettingsWindow
    T.shown(win, "settings window")
    local W = env.WenillaCore
    for i = 1, table.getn(W.ADDONS) do
        local nav = env["ClassicPlus_NavBtn" .. i]
        -- more addons than rows: scroll the list down to it
        for _ = 1, 20 do if nav:IsVisible() then break end api.wheel(nav:GetParent(), -1) end
        api.click(nav)
        local id = env.ClassicPlus_Manager.currentAddon
        T.eq(id, W.ADDONS[i], "nav button " .. i)
        T.ok(W:IsActive(id), id .. " active before")
        api.click(env.ClassicPlus_MasterCB)
        T.no(W:IsActive(id), id .. " should be off after unticking Enabled")
        api.tick(env, 1)
        for j = 1, 6 do
            local cb = env["ClassicPlus_OptCB" .. j]
            if cb:IsVisible() then api.click(cb); api.tick(env, 0.3); api.click(cb) end
        end
        api.click(env.ClassicPlus_MasterCB)
        T.ok(W:IsActive(id), id .. " should be back on")
        api.tick(env, 1)
    end
    api.click(env.ClassicPlus_BtnVan)
    T.ok(W.isVanillaMode, "Pure Vanilla button")
    api.tick(env, 1)
    api.click(env.ClassicPlus_BtnCP)
    T.no(W.isVanillaMode, "Classic+ button")
    api.tick(env, 1)
    T.ok(api.press_escape(env), "Escape closes the manager")
    T.hidden(win)
    env.__slash("/cplus")
    T.shown(win, "/cplus alias")
    env.__slash("/addons")
    T.hidden(win)
    -- the Esc menu gets an AddOns button that opens the manager
    env.GameMenuFrame:Show()
    T.eq(env.GameMenuButtonAddOns:GetText(), "AddOns")
    api.click(env.GameMenuButtonAddOns)
    T.hidden(env.GameMenuFrame, "the Esc menu closes")
    T.shown(win, "and the manager opens")
    api.click_text(env, "Close", win)
    T.hidden(win)
end)

T.test("smoke: Pure Vanilla hides every Classic+ window and restores them", function()
    local env = T.suite()
    env.__slash("/wnl demo")
    api.tick(env, 3)
    T.shown(env.Chronicle_Frame)
    env.__slash("/vanilla")
    T.ok(env.WenillaCore.isVanillaMode)
    api.tick(env, 1)
    for _, n in ipairs({ "Chronicle_Frame", "Vanguard_Frame", "Castline_TargetBar", "Rally_PullBar", "Compass_RingFrame", "PersonaMinimapButton" }) do
        T.hidden(env[n], n .. " in Pure Vanilla")
    end
    T.no(env.WenillaCore.demoRunning, "Pure Vanilla stops the demo")
    T.eq(env.WenillaCore:SendCommand("x"), nil, "no commands in Pure Vanilla")
    env.__slash("/purevanilla")
    T.no(env.WenillaCore.isVanillaMode)
    api.tick(env, 1)
    T.shown(env.Chronicle_Frame, "Chronicle back")
    T.shown(env.Compass_RingFrame, "Compass back")
end)

T.test("smoke: in Pure Vanilla the slash commands do nothing", function()
        local env = T.suite({ party = { { name = "Brakkus", class = "WARRIOR" } },
            bags = { [0] = { size = 16, items = { { 7073, 2 } } } } })
        env.__slash("/vanilla")
        env.__slash("/guilds")
        env.__slash("/rally")
        env.__slash("/pull 5")
        env.__slash("/rally check")
        api.open_merchant(env, { items = {} })
        env.__slash("/scrap")
        api.tick(env, 1)
        T.hidden(env.Concord_Frame, "Concord board")
        T.hidden(env.Rally_Frame, "Rally board")
        T.eq(#env.__addon_sent, 0, "addon messages sent to the group")
        T.ok(api.bag_slot(env, 0, 1), "grey sold by a switched-off Scrapper")
    end)

T.test("smoke: malformed server packets never raise", function()
    local env = T.suite({ bags = { [0] = { size = 16, items = { { 2589, 20 } } } } })
    api.connect(env)
    api.open_merchant(env, { items = { { id = 2589, price = 5 } } })
    env.__slash("/bags bank")
    env.__slash("/guilds")
    local bodies = { "", "-", ";", ";;;", ",", ",,,,,,,", "x", "x;y;z", "1,2", "a,b,c,d,e,f,g,h,i",
        string.rep("9", 300), "~~~~", "L~", "L~~~~~~", "inspect,", "inspect,;,,", "stop", "stop,,,",
        "announcement,", "pull,abc", "pull,-5", "check", "target,,,,,,", "plate,X,Y,-100,1", "0,0,0,0;0,0,0,0",
        "S,1,2,3", "Boss;S,x,y,z", "Mob;icon,", "1,1;0,,,,;x,y,z", "999999999999,1,1,1" }
    for _, tag in ipairs({ "CH", "CP", "VG", "CL", "CO", "VT", "LG", "SC", "VS", "RL" }) do
        for _, b in ipairs(bodies) do
            api.server_packet(env, tag, b)
            api.tick(env, 0.1)
        end
    end
    api.tick(env, 8)
    env.GameTooltip:SetBagItem(0, 1)
    env.GameTooltip:SetMerchantItem(1)
end)
