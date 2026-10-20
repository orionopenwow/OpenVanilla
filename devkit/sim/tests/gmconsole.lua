-- Console: the hidden GM console. /ovgm asks the realm ".wnl gm hi"; only "GM OK <level>" opens it.
-- The realm feeds it GR (roster) and GB (bug reports); everything it does is a GM chat command.
local T, api = ...

local ROW_A = "Brakkus,60,2,1,0,1637,1,1600.5,-4400.2,10.1,4200,5000,40,100,1,1234567,BRAKACC,0,0,0,1,85,0,Iron Horde,203.0.113.7"
local ROW_B = "Ilyndra,42,4,8,1,1519,0,-8900,550,94,0,2100,0,3000,0,52000,ILYACC,0,600,1,0,140,0,,198.51.100.4"
local ROW_C = "Zed,12,8,4,0,141,1,9900,1000,1300,300,300,80,100,3,99,ZEDACC,1,0,2,0,40,1,The, Commas,203.0.113.7"
local ROW_D = "Mox,30,7,9,1,1584,230,600,-200,-60,900,1000,500,1100,0,10,MOXACC,0,0,0,0,60,0,,10.0.0.9"
local ROSTER = ROW_A .. ";" .. ROW_B .. ";" .. ROW_C .. ";" .. ROW_D

local function client(opts)
    local env = T.addon("Console", opts)
    api.connect(env)
    return env
end

-- a GM client with the window open and the roster in
local function gm(opts)
    local env = client(opts)
    env.__slash("/ovgm")
    api.server_packet(env, "GM", "OK 3")
    api.server_packet(env, "GR", ROSTER)
    return env
end

local function sent(env)
    local out = {}
    for _, m in ipairs(env.__chat_sent) do
        if string.sub(m.msg, 1, 1) == "." and string.sub(m.msg, 1, 5) ~= ".wnl " then table.insert(out, m.msg) end
    end
    return out
end

-- click the button whose label is exactly 'label' under 'root' (api.click_text matches the first
-- text containing it, which may be a plain label)
local function press(env, label, root, button)
    for _, r in ipairs(env.__regions) do
        if r:GetObjectType() == "FontString" and api.visible(r:GetText()) == label and r:IsVisible() then
            local b, q, under = nil, r:GetParent(), false
            while q do
                if not b and q:GetObjectType() == "Button" then b = q end
                if q == root then under = true end
                q = q:GetParent()
            end
            if b and under then return api.click(b, button) end
        end
    end
    error("no visible button '" .. label .. "'", 2)
end

local function names(view)
    local out = {}
    for _, p in ipairs(view) do table.insert(out, p.name) end
    return table.concat(out, ",")
end

T.test("Console: loads silently, with no minimap button and no Addons-window entry", function()
    local env = client()
    local before = api.chat_text(env)
    T.no(string.find(before, "Console", 1, true), "nothing printed about the console at load")
    local plain = T.addon("WenillaCore", { name = "Plain" })
    api.connect(plain)
    T.eq(#api.chat_lines(env), #api.chat_lines(plain), "the same chat lines as the core alone")
    T.eq(env.OVConsole_Frame, nil, "no window until a GM opens it")
    for _, id in ipairs(env.WenillaCore.ADDONS) do T.no(id == "Console", "not in the Addons window") end
    T.eq(env.GetAddOnMetadata("Console", "X-Unlisted"), "1", "the .toc keeps it out of the Workshop")
end)

T.test("Console: a player's /ovgm asks the realm, gets no answer and shows nothing", function()
    local env = client()
    local before = api.chat_text(env)
    env.__slash("/ovgm")
    T.eq(env.__wnl[#env.__wnl], "gm hi")
    env.__slash("/gmc")
    T.eq(env.__wnl[#env.__wnl], "gm hi", "/gmc is the same command")
    api.tick(env, 10)
    T.eq(env.OVConsole_Frame, nil, "no window")
    T.no(env.OVConsole.gm)
    T.eq(api.chat_text(env), before, "nothing printed, no error")
    T.eq(#env.__popups, 0)
    -- the roster feed is ignored for a non-GM even if one turned up
    api.server_packet(env, "GR", ROSTER)
    T.eq(#env.OVConsole.roster, 0)
    T.eq(env.OVConsole_Frame, nil)
end)

T.test("Console: GM OK opens the window; the answer is remembered for the session", function()
    local env = client()
    -- an unasked GM line opens nothing
    api.server_packet(env, "GM", "OK 3")
    T.eq(env.OVConsole_Frame, nil, "only /ovgm opens it")
    env.__slash("/ovgm")
    api.server_packet(env, "GM", "OK 3")
    T.shown(env.OVConsole_Frame, "console window")
    T.eq(env.OVConsole.level, 3)
    T.eq(env.__wnl[#env.__wnl], "gm roster", "asks for the roster when it opens")
    -- toggles without asking again
    local n = #env.__wnl
    env.__slash("/gmc")
    T.hidden(env.OVConsole_Frame)
    env.__slash("/ovgm")
    T.shown(env.OVConsole_Frame)
    T.eq(env.__wnl[n + 1], "gm roster", "no second 'gm hi'")
    -- refreshes every 5 s while open
    local count = 0
    api.tick(env, 11)
    for i = n + 1, #env.__wnl do if env.__wnl[i] == "gm roster" then count = count + 1 end end
    T.ok(count >= 3, "roster asked at open and twice more in 11 s, got " .. count)
    env.OVConsole_Frame:Hide()
    n = #env.__wnl
    api.tick(env, 11)
    T.eq(#env.__wnl, n, "no requests while closed")
end)

T.test("Console: Escape closes the window", function()
    local env = gm()
    T.shown(env.OVConsole_Frame)
    T.ok(api.press_escape(env))
    T.hidden(env.OVConsole_Frame)
end)

T.test("Console: the roster is parsed and listed", function()
    local env = gm()
    local C = env.OVConsole
    T.eq(#C.roster, 4)
    local b = C.byName.Brakkus
    T.eq(b.level, 60); T.eq(b.className, "Warrior"); T.eq(b.raceName, "Orc"); T.eq(b.zoneName, "Orgrimmar")
    T.eq(b.copper, 1234567); T.eq(b.account, "BRAKACC"); T.eq(b.guild, "Iron Horde"); T.eq(b.latency, 85)
    T.near(b.frac, 0.84, 1e-9)
    T.eq(C.byName.Zed.guild, "The, Commas", "a comma in the guild name keeps the address last")
    T.eq(C.byName.Zed.ip, "203.0.113.7")
    T.eq(C.byName.Ilyndra.state, 1)
    T.eq(C.byName.Mox.zoneName, "Blackrock Depths")
    -- same address on two characters
    T.eq(table.concat(b.sameIp, ","), "Zed")
    T.eq(C.byName.Ilyndra.sameIp, nil)
    T.eq(C.MaskIp("203.0.113.7"), "203.0.x.x")
    local page = C.pages.players
    for _, n in ipairs({ "Brakkus", "Ilyndra", "Zed", "Mox", "Orgrimmar", "BRAKACC", "85 ms", "123g" }) do
        T.ok(api.screen_has(env, n, page), n .. " on the Players tab")
    end
    T.ok(api.screen_has(env, "Same IP", page), "same-IP flag")
    T.ok(api.screen_has(env, "Muted", page), "muted flag")
    T.ok(api.screen_has(env, "Dead", page), "dead flag")
    T.ok(api.screen_has(env, "GM", page), "GM flag")
    T.no(api.screen_has(env, "203.0.113.7", env.OVConsole_Frame), "addresses are never shown in full")
    T.ok(api.screen_has(env, "4 players online", env.OVConsole_Frame))
    -- an empty body empties the list
    api.server_packet(env, "GR", "")
    T.eq(#C.roster, 0)
    T.ok(api.screen_has(env, "Nobody is in the world right now.", page))
    -- junk never raises
    api.server_packet(env, "GR", "a,b;;,,,;x")
    T.eq(#C.roster, 0)
end)

T.test("Console: the roster sorts by any column and filters", function()
    local env = gm()
    local C = env.OVConsole
    T.eq(names(C:View()), "Brakkus,Ilyndra,Mox,Zed", "by name")
    T.ok(api.screen_has(env, "Name ^", C.pages.players), "the sorted column is marked")
    api.click(C.pages.players.heads[2])   -- Lvl
    T.eq(names(C.view), "Brakkus,Ilyndra,Mox,Zed", "level: highest first")
    T.eq(C.sortKey, "level")
    T.ok(C.sortDesc)
    api.click(C.pages.players.heads[2])   -- Lvl
    T.eq(names(C.view), "Zed,Mox,Ilyndra,Brakkus", "level again: lowest first")
    api.click(C.pages.players.heads[7])   -- Gold
    T.eq(names(C.view), "Brakkus,Ilyndra,Zed,Mox", "gold: richest first")
    api.click(C.pages.players.heads[9])   -- Ping
    T.eq(names(C.view), "Ilyndra,Brakkus,Mox,Zed")
    api.click(C.pages.players.heads[1])   -- Name
    T.eq(names(C.view), "Brakkus,Ilyndra,Mox,Zed")
    -- the first row on screen follows the sort
    T.eq(C.pages.players.list.rows[1].cells.name:GetText(), "Brakkus")
    api.type(C.pages.players.filter, "orgrim")
    T.eq(names(C.view), "Brakkus", "filter by zone")
    api.type(C.pages.players.filter, "zedacc")
    T.eq(names(C.view), "Zed", "filter by account")
    api.type(C.pages.players.filter, "mage")
    T.eq(names(C.view), "Ilyndra", "filter by class")
    T.ok(api.screen_has(env, "1 of 4 shown", C.pages.players))
    api.type(C.pages.players.filter, "nobody here")
    T.ok(api.screen_has(env, "Nobody matches the filter.", C.pages.players))
    api.type(C.pages.players.filter, "")
    T.eq(#C.view, 4)
end)

T.test("Console: action buttons send the GM commands; kick waits for the confirmation", function()
    local env = gm()
    local C = env.OVConsole
    local page = C.pages.actions
    -- nothing picked: nothing sent
    C:ShowTab("actions")
    press(env, "Revive", page)
    T.eq(#sent(env), 0)
    T.ok(api.screen_has(env, "Pick a player on the Players tab first.", env.OVConsole_Frame))
    -- pick Brakkus by clicking his row, right-click goes to Actions
    C:ShowTab("players")
    api.click(C.pages.players.list.rows[1], "RightButton")
    T.eq(C.selected, "Brakkus")
    T.shown(page, "right-click opens Actions")
    T.ok(api.screen_has(env, "Level 60 Orc Warrior", page))
    press(env, "Go to them", page)
    press(env, "Bring them here", page)
    press(env, "Revive", page)
    press(env, "Info", page)
    press(env, "Orgrimmar", page)
    press(env, "GM Island", page)
    api.type(page.mins, "15")
    press(env, "Mute", page)
    press(env, "Unmute", page)
    T.eq(table.concat(sent(env), "|"), ".appear Brakkus|.summon Brakkus|.revive Brakkus|.pinfo Brakkus"
        .. "|.tele name Brakkus Orgrimmar|.tele name Brakkus GMIsland|.mute Brakkus 15|.unmute Brakkus")
    -- whisper is an ordinary whisper
    api.type(page.msg, "Hello there")
    press(env, "Whisper", page)
    local w = env.__chat_sent[#env.__chat_sent]
    T.eq(w.kind, "WHISPER"); T.eq(w.target, "Brakkus"); T.eq(w.msg, "Hello there")
    -- kick: nothing until the confirmation is accepted
    local n = #sent(env)
    press(env, "Kick", page)
    T.eq(#sent(env), n, "kick waits for the confirmation")
    T.eq(env.StaticPopup1.which, "OVCONSOLE_CONFIRM")
    T.has(env.StaticPopup1Text:GetText(), "Kick Brakkus")
    api.popup_click(env, "OVCONSOLE_CONFIRM", 2)
    T.eq(#sent(env), n, "cancelled: no kick")
    press(env, "Kick", page)
    api.popup_click(env, "OVCONSOLE_CONFIRM", 1)
    T.eq(sent(env)[n + 1], ".kick Brakkus")
    -- jail: confirmation, then GM Island and a mute
    press(env, "Jail", page)
    T.eq(#sent(env), n + 1)
    api.popup_click(env, "OVCONSOLE_CONFIRM", 1)
    T.eq(sent(env)[n + 2], ".tele name Brakkus GMIsland")
    T.eq(sent(env)[n + 3], ".mute Brakkus 15")
    -- reset talents asks too
    press(env, "Reset talents", page)
    api.popup_click(env, "OVCONSOLE_CONFIRM", 1)
    T.eq(sent(env)[n + 4], ".reset talents Brakkus")
    -- ban: needs a reason, then a confirmation; the duration button cycles
    press(env, "Ban account", page)
    T.eq(#sent(env), n + 4, "no reason: no ban")
    T.no(env.StaticPopup1:IsShown())
    press(env, "7 days", page)
    T.ok(api.screen_has(env, "30 days", page))
    api.type(page.reason, "Gold \"selling\" spam")
    press(env, "Ban account", page)
    T.has(env.StaticPopup1Text:GetText(), "BRAKACC")
    T.eq(#sent(env), n + 4)
    api.popup_click(env, "OVCONSOLE_CONFIRM", 1)
    T.eq(sent(env)[n + 5], ".ban account BRAKACC 30d \"Gold 'selling' spam\"")
end)

T.test("Console: Everyone tab announces, notifies and runs any command with a history", function()
    local env = gm()
    local C = env.OVConsole
    C:ShowTab("everyone")
    local page = C.pages.everyone
    api.type(page.text, "Restart in 5 minutes")
    press(env, "In chat", page)
    api.type(page.text, "Back soon")
    press(env, "On screen", page)
    api.type(page.cmd, "gm visible off")
    api.press_enter(page.cmd)
    api.type(page.cmd, ".gps")
    press(env, "Run", page)
    T.eq(table.concat(sent(env), "|"), ".announce Restart in 5 minutes|.notify Back soon|.gm visible off|.gps")
    T.eq(table.concat(C.history, "|"), ".gm visible off|.gps")
    T.ok(api.screen_has(env, ".gm visible off", page.recent), "recent list")
    press(env, ".recall", page)
    T.eq(page.cmd:GetText(), ".recall", "a common command goes into the box")
    -- the realm's answers land in the output strip
    api.fire(env, "CHAT_MSG_SYSTEM", "You are at Stormwind City.")
    T.ok(api.screen_has(env, "You are at Stormwind City.", env.OVConsole_Frame))
end)

T.test("Console: bug reports are asked for on the tab and listed", function()
    local env = gm()
    local C = env.OVConsole
    local n = #env.__wnl
    C:ShowTab("bugs")
    T.eq(env.__wnl[n + 1], "gm bugs", "asks when the tab opens")
    api.server_packet(env, "GB", "7,1760000000,Ilyndra,42,8,0,12,-9449.5,64.3,56.5,quest,Hogger, again, is stuck;"
        .. "9,1760003600,Zed,12,4,1,141,9900,1000,1300,,The tree is floating")
    T.eq(#C.bugs, 2)
    T.eq(C.bugs[1].id, 9, "newest first")
    T.eq(C.bugs[2].text, "Hogger, again, is stuck", "commas in the text survive")
    T.eq(C.bugs[2].zone, 12)
    local page = C.pages.bugs
    T.ok(api.screen_has(env, "#7", page))
    T.ok(api.screen_has(env, "Elwynn Forest", page))
    api.click(page.list.rows[2])
    T.eq(C.bugSelected, 7)
    T.ok(api.screen_has(env, "Hogger, again, is stuck", page))
    press(env, "Go there", page)
    T.eq(sent(env)[#sent(env)], ".go xyz -9449.5 64.3 56.5 0")
    press(env, "Go to reporter", page)
    T.eq(sent(env)[#sent(env)], ".appear Ilyndra")
    api.server_packet(env, "GB", "")
    T.ok(api.screen_has(env, "No bug reports.", page))
end)

T.test("Console: Map places dots by continent and a click picks the player", function()
    local env = gm()
    local C = env.OVConsole
    C:ShowTab("map")
    local page = C.pages.map
    T.eq(page.tiles[1]:GetTexture(), "Interface\\WorldMap\\Azeroth\\Azeroth1")
    T.ok(page.shown.Ilyndra, "Ilyndra (Stormwind) on the Eastern Kingdoms")
    T.no(page.shown.Brakkus, "Brakkus is on Kalimdor")
    T.ok(api.screen_has(env, "Mox (Blackrock Depths)", page), "players inside instances are listed under the map")
    press(env, "Kalimdor", page)
    T.eq(page.tiles[12]:GetTexture(), "Interface\\WorldMap\\Kalimdor\\Kalimdor12")
    T.ok(page.shown.Brakkus and page.shown.Zed)
    local fx, fy = C.MapPoint(1, 1600.5, -4400.2)
    T.ok(fx > 0.5 and fx < 0.7 and fy > 0.4 and fy < 0.5, "Orgrimmar sits east of centre: " .. fx .. ", " .. fy)
    api.click(page.shown.Zed)
    T.eq(C.selected, "Zed")
end)

T.test("Console: Armory shows the sheet, inspects when near, and says to go there when not", function()
    local env = gm({ name = "Gamemaster" })
    local C = env.OVConsole
    local near = false
    env.CheckInteractDistance = function(u, i) return near and 1 or nil end
    local inspected = {}
    env.NotifyInspect = function(u) table.insert(inspected, u) end
    env.TargetByName = function(n) api.set_target(env, { name = n, class = "WARRIOR", level = 60, isPlayer = true }) end
    C:Select("Brakkus")
    C:ShowTab("armory")
    local page = C.pages.armory
    T.ok(api.screen_has(env, "Guild: <Iron Horde>", page))
    T.ok(api.screen_has(env, "Orgrimmar", page))
    T.ok(api.screen_has(env, "Go to them to inspect (.appear)", page), "out of range")
    T.eq(#inspected, 0, "opening the tab never retargets")
    press(env, "Go to them", page)
    T.eq(sent(env)[#sent(env)], ".appear Brakkus")
    -- in range now: Inspect targets them and reads the gear
    near = true
    env.__inventory[1] = 2589
    press(env, "Inspect", page)
    T.eq(env.UnitName("target"), "Brakkus")
    T.eq(inspected[1], "target")
    T.ok(C.gear.Brakkus[1] and C.gear.Brakkus[1].link, "head slot read")
    T.ok(api.screen_has(env, "In range", page))
    T.shown(page.full, "full inspect offered in range")
end)

T.test("Console: GM command answers show in the strip only for a GM", function()
    local env = client()
    api.fire(env, "CHAT_MSG_SYSTEM", "Player Brakkus kicked.")
    T.eq(#env.OVConsole.out, 0, "not collected before the realm said GM OK")
    env.__slash("/ovgm")
    api.server_packet(env, "GM", "OK 2")
    api.fire(env, "CHAT_MSG_SYSTEM", "Player Brakkus kicked.")
    T.eq(env.OVConsole.out[#env.OVConsole.out], "Player Brakkus kicked.")
    T.ok(api.screen_has(env, "Player Brakkus kicked.", env.OVConsole_Frame))
end)
