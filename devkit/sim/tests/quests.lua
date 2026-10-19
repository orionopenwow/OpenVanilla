-- Quests: minimap ring and stock border, quest pins, tracking icons, arrow (quests and corpse),
-- tracker, tooltips, the L quest log (grouping, filters, sorting, detail, abandon/undo, history,
-- share, party progress, nearby, options) and the realm packets (CP, NP, QZ, QM).
local T, api = ...

local PINS = "101,0.45,0.60,OBJ,The Jasperlode Mine;102,0.40,0.70,GIVER,Marshal Dughan;103,0.50,0.50,TURNIN;bad,x,y,OBJ"

local LOG = {
    { header = "Elwynn Forest" },
    { title = "Kobold Camp Cleanup", level = 6, objectives = { { text = "Kobold Vermin slain: 4/8", type = "monster" } },
        desc = "Clear the kobolds out of the camp north of Northshire.", objText = "Kill 8 Kobold Vermin.",
        rewards = { { id = 2575 } }, choices = { { id = 1203 }, { id = 858 } }, money = 250 },
    { title = "Wolves Across the Border", level = 7, objectives = { { text = "Tough Wolf Meat: 2/8", type = "item" } } },
    { title = "Report to Goldshire", level = 5, complete = 1, objectives = {} },
    { title = "Lost Necklace", level = 2, objectives = { { text = "Find the necklace", type = "event" } } },
    { header = "Westfall" },
    { title = "The Defias Brotherhood", level = 11, objectives = { { text = "Report to Gryan Stoutmantle", type = "event" } } },
    { title = "Red Silk Bandanas", level = 22, tag = "Dungeon", objectives = { { text = "Red Silk Bandana: 0/10", type = "item" } } },
    { header = "Hunter" },
    { title = "Taming the Beast", level = 10, tag = "Elite", objectives = { { text = "Tame a Mangy Wolf", type = "event" } } },
}

local function setup(opts)
    opts = opts or {}
    opts.level = opts.level or 8
    local env = T.addon("Quests", opts)
    if opts.log ~= false then
        api.set_quests(env, opts.log or LOG)
        api.tick(env, 0.3)
    end
    return env, env.Compass
end

local function shownPins(env)
    local n = 0
    for _, p in ipairs(env.Compass.pinPool) do if p:IsShown() then n = n + 1 end end
    return n
end

local function menuItems(env)
    local out = {}
    for _, b in ipairs(env.WenillaCore_Menu.buttons) do
        if b:IsShown() then out[api.visible(b.text:GetText())] = b.check:IsShown() and "on" or "off" end
    end
    return out
end

-- -- Minimap frame -----------------------------------------------------------------------------------

T.test("Quests: the Wildwood ring replaces the stock minimap border by default", function()
    local env = setup({ log = false })
    T.shown(env.Compass_RingFrame, "ring frame")
    T.shown(env.Compass_RingTexture, "ring art")
    T.has(env.Compass_RingTexture:GetTexture(), "CompassRing", "Wildwood art")
    T.hidden(env.MinimapBorder, "stock border")
    T.hidden(env.MinimapBorderTop, "stock top border")
    T.ok(env.Compass_RingFrame:GetFrameLevel() > env.MinimapBackdrop:GetFrameLevel(), "ring above the stock backdrop")
    local _, rel = env.MinimapZoomIn:GetPoint(1)
    T.eq(rel, env.Compass_RingFrame, "zoom button set on the ring")
    T.ok(env.MinimapZoomIn:GetFrameLevel() > env.Compass_RingFrame:GetFrameLevel(), "zoom button above the ring")
    local p, zrel, rp = env.MinimapZoneTextButton:GetPoint(1)
    T.eq(p .. " " .. rp, "BOTTOM TOP", "zone name above the ring")
    T.eq(zrel, env.Compass_RingFrame)
    local _, trel = env.MiniMapTrackingFrame:GetPoint(1)
    T.eq(trel, env.Compass_RingFrame, "tracking button on the ring")
end)

T.test("Quests: /compass hides the ring and gives the stock frame back; themes change the art", function()
    local env = setup({ log = false })
    env.__slash("/compass")
    T.has(api.chat_text(env), "Minimap ring hidden.")
    T.hidden(env.Compass_RingTexture)
    T.shown(env.MinimapBorder, "stock border back")
    local _, rel, _, x, y = env.MinimapZoomIn:GetPoint(1)
    T.eq(rel, env.MinimapBackdrop, "zoom button back in its stock place")
    env.__slash("/compass")
    T.has(api.chat_text(env), "Minimap ring shown.")
    T.hidden(env.MinimapBorder)
    env.__slash("/compass theme bronze")
    T.has(env.Compass_RingTexture:GetTexture(), "CompassRing_Bronze")
    T.has(api.chat_text(env), "Minimap ring: Dwarven Bronze.")
    env.__slash("/compass theme")
    T.has(env.Compass_RingTexture:GetTexture(), "CompassRing", "next theme wraps to Wildwood")
    env.__slash("/compass theme nope")
    T.has(api.chat_text(env), "Minimap ring themes: wildwood, stone, ironoak, runestone, bronze.")
    api.click(env.Compass_Rose, "RightButton")
    T.eq(menuItems(env)["Wildwood"], "on", "right-click: the theme menu")
    api.click_text(env, "Stone & Leather", env.WenillaCore_Menu)
    T.has(env.Compass_RingTexture:GetTexture(), "CompassRing_Stone")
end)

T.test("Quests: a ring missing from the remembered art folder still loads from the other one", function()
    -- an older patch: the TGA folder lacks the Bronze ring, the BLP folder has it
    local env = setup({ log = false, saved = { WenillaCore_Config = { settings = { Quests = { ringTheme = "bronze" } } } },
        art = function(path) return not string.find(path, "Media\\CompassRing_Bronze", 1, true) end })
    T.eq(env.WenillaCore.artRoot, "Interface\\AddOns\\WenillaCore\\Media\\", "the first art loaded set the root")
    T.eq(env.Compass_RingTexture:GetTexture(), "Interface\\ClassicPlus\\CompassRing_Bronze")
    T.shown(env.Compass_RingTexture)
    T.hidden(env.MinimapBorder)
end)

T.test("Quests: without ring art the stock border stays; Pure Vanilla restores the stock minimap", function()
    local env = setup({ log = false, art = false })
    T.hidden(env.Compass_RingTexture, "no art: no ring")
    T.shown(env.MinimapBorder, "the stock border is kept")
    local env2 = setup({ log = false, name = "Ilyndra" })
    T.hidden(env2.MinimapBorder)
    env2.__slash("/vanilla")
    T.shown(env2.MinimapBorder, "Pure Vanilla: stock border")
    T.shown(env2.MinimapBorderTop)
    T.hidden(env2.Compass_RingFrame)
    local _, rel = env2.MinimapZoneTextButton:GetPoint(1)
    T.eq(rel, env2.MinimapCluster, "zone name back on the cluster")
    env2.__slash("/vanilla")
    T.hidden(env2.MinimapBorder, "back to the ring")
end)

-- -- Quest pins (CP) -----------------------------------------------------------------------------------

T.test("Quests: CP pins sit on the minimap when in view, else on the ring, with yards in the tooltip", function()
    local env, Q = setup({ log = false })
    api.server_packet(env, "CP", PINS)
    T.eq(table.getn(Q.pins), 3, "the malformed record is skipped")
    T.eq(shownPins(env), 3)
    -- 101 is ~170 yards from Goldshire: on the minimap; 103 is far: on the ring
    local p1, p3
    for _, p in ipairs(Q.pinPool) do
        if p.node and p.node.questId == "101" then p1 = p end
        if p.node and p.node.questId == "103" then p3 = p end
    end
    T.eq(p1.where, "map")
    local _, rel = p1:GetPoint(1)
    T.eq(rel, Q.ring, "pins are anchored to the ring, which follows the minimap")
    T.eq(p3.where, "ring")
    api.enter(p1)
    local tip = api.tooltip_text(env)
    T.has(tip, "The Jasperlode Mine"); T.has(tip, "Objective"); T.has(tip, "yd away")
    api.enter(p3)
    T.has(api.tooltip_text(env), "Quest #103", "no title: the quest id")
    T.has(api.tooltip_text(env), "Ready to turn in")
    api.enter(env.Compass_Rose)
    T.has(api.tooltip_text(env), "3 quest pins in this zone")
    -- titles may contain commas; kinds may carry target ids
    api.server_packet(env, "CP", "7,0.9,0.1,OBJ:i750:m299,Wolves, Wolves Everywhere")
    T.eq(Q.pins[1].title, "Wolves, Wolves Everywhere")
    T.eq(Q.pins[1].kind, "OBJ")
    T.eq(Q.itemIds[750], "Wolves, Wolves Everywhere")
end)

T.test("Quests: ring pins move around the ring as the player moves", function()
    local env, Q = setup({ log = false })
    api.server_packet(env, "CP", "101,0.90,0.50,OBJ,East")
    env.__map.x, env.__map.y = 0.50, 0.50
    api.tick(env, 0.3)
    local _, rel, _, x1, y1 = env.Compass_Pin1:GetPoint(1)
    T.eq(rel, env.Compass_RingFrame)
    T.ok(x1 > 70 and math.abs(y1) < 1, "pin due east of the player: " .. x1 .. "," .. y1)
    env.__map.x, env.__map.y = 0.90, 0.95           -- now the target is due north
    api.tick(env, 0.3)
    local _, _, _, x2, y2 = env.Compass_Pin1:GetPoint(1)
    T.ok(y2 > 70 and math.abs(x2) < 1, "pin due north: " .. x2 .. "," .. y2)
end)

T.test("Quests: coordinates pill, pin settings and clearing", function()
    local env = setup({ log = false })
    api.tick(env, 0.3)
    T.shown(env.Compass_Coords)
    T.ok(api.screen_has(env, "42.1, 65.9", env.Compass_Coords), "coordinates text")
    env.ClassicPlus_Manager:SetSetting("Quests", "showGivers", false)
    api.server_packet(env, "CP", PINS)
    T.eq(shownPins(env), 2, "giver pin hidden by its setting")
    env.ClassicPlus_Manager:SetSetting("Quests", "showCoords", false)
    T.hidden(env.Compass_Coords)
    api.server_packet(env, "CP", "")
    T.eq(shownPins(env), 0, "an empty CP clears the pins")
    api.server_packet(env, "CP", PINS)
    api.fire(env, "ZONE_CHANGED_NEW_AREA")
    T.eq(shownPins(env), 0, "a new zone clears the pins until the server sends its own")
    env.__map.x, env.__map.y = 0, 0                 -- instance / no map position
    env.ClassicPlus_Manager:SetSetting("Quests", "showCoords", true)
    api.tick(env, 0.3)
    T.hidden(env.Compass_Coords)
end)

T.test("Quests: world map pins for the zone the map shows, with focus from Show on map", function()
    local env, Q = setup()
    api.server_packet(env, "CP", "1,0.30,0.30,OBJ,Kobold Camp Cleanup;2,0.6,0.6,GIVER,A New Quest")
    env.WorldMapFrame:Show()
    api.fire(env, "WORLD_MAP_UPDATE")
    T.shown(env.Compass_MapPin1)
    T.shown(env.Compass_MapPin2)
    T.eq(Q.mapPinsShown, 2)
    local _, _, _, x, y = env.Compass_MapPin1:GetPoint(1)
    T.near(x, 0.30 * 1002, 1e-6, "pin placed on the map's width")
    env.WorldMapFrame:Hide()
    T.eq(Q:ShowOnMap("Kobold Camp Cleanup"), 1, "one pin for the quest in this zone")
    T.shown(env.WorldMapFrame, "Show on map opens the world map")
    for i = 1, 2 do
        local p = env["Compass_MapPin" .. i]
        if p.node.key == "Kobold Camp Cleanup" then T.eq(p:GetAlpha(), 1) else T.near(p:GetAlpha(), 0.35, 1e-6, "others dimmed") end
    end
    api.click(env.Compass_MapPin1)
    T.ok(Q.waypoint, "clicking a map pin points the arrow")
end)

-- -- Tracking: repair / sell / flight ... -------------------------------------------------------------

T.test("Quests: tracking menu on the compass rose; Repair and Sell on by default", function()
    local env, Q = setup({ log = false })
    api.click(env.Compass_Rose)
    local m = menuItems(env)
    T.eq(m["Repair"], "on"); T.eq(m["Sell"], "on")
    T.eq(m["Flight masters"], "off"); T.eq(m["Innkeepers"], "off"); T.eq(m["Trainers"], "off"); T.eq(m["Bankers"], "off")
    T.ok(m["Find Herbs (not learned)"], "herbs greyed without the spell")
    api.click_text(env, "Innkeepers", env.WenillaCore_Menu)
    T.ok(Q:Get("trackInn"), "Innkeepers on")
    api.click(env.Compass_Rose)
    T.eq(menuItems(env)["Innkeepers"], "on")
    -- Shift-click still opens the world map
    env.__keys.shift = true
    api.click(env.Compass_Rose)
    env.__keys.shift = nil
    T.shown(env.WorldMapFrame)
end)

T.test("Quests: Find Herbs and Find Minerals cast from the menu when known", function()
    local env, Q = setup({ log = false, spells = { "Attack", "Find Herbs", "Find Minerals" } })
    api.click(env.Compass_Rose)
    T.eq(menuItems(env)["Find Herbs"], "off")
    api.click_text(env, "Find Herbs", env.WenillaCore_Menu)
    T.eq(env.__casts[1].spell, "Find Herbs")
    api.click(env.Compass_Rose)
    T.eq(menuItems(env)["Find Herbs"], "on", "shows the active tracking")
    api.click_text(env, "Find Herbs", env.WenillaCore_Menu)
    T.eq(env.__tracking, nil, "clicking it again cancels the tracking")
end)

T.test("Quests: built-in repair and vendor icons in Goldshire with what they do and yards", function()
    local env, Q = setup({ log = false })
    api.tick(env, 0.3)
    local byName = {}
    for _, m in ipairs(Q.npcPool) do if m:IsShown() and m.npc then byName[m.npc.name] = m end end
    local smith = byName["Andrew Krighton"]
    T.ok(smith, "Goldshire armourer shown")
    T.eq(smith.where, "map", "in view: on the minimap")
    T.eq(smith.kind, "R")
    T.has(smith.tex:GetTexture(), "Quests_Anvil")
    T.ok(byName["Brog Hamfist"], "general goods vendor shown")
    T.has(byName["Brog Hamfist"].tex:GetTexture(), "Quests_CoinBag")
    T.eq(byName["Innkeeper Farley"], nil, "innkeepers are off by default")
    api.enter(smith)
    local tip = api.tooltip_text(env)
    T.has(tip, "Andrew Krighton"); T.has(tip, "<Armorer & Shieldcrafter>")
    T.has(tip, "Repairs · Sells armour and shields"); T.has(tip, "yd away")
    -- the nearest repairer of a far-off town sits on the ring
    local onRing = 0
    for _, m in ipairs(Q.npcPool) do if m:IsShown() and m.where == "ring" then onRing = onRing + 1 end end
    T.ok(onRing <= 2, "at most one ring icon per kind, got " .. onRing)
    -- turning Repair off: repairers that also sell show the coin bag
    env.ClassicPlus_Manager:SetSetting("Quests", "trackRepair", false)
    api.tick(env, 0.3)
    T.has(smith.tex:GetTexture(), "Quests_CoinBag")
    api.click(smith)
    T.eq(Q.waypoint.title, "Andrew Krighton", "click an icon to point the arrow there")
end)

T.test("Quests: the built-in list covers the six starting zones, their first towns and the capitals", function()
    local env, Q = setup({ log = false })
    local need = {
        ["Elwynn Forest"] = { "Godric Rothgar", "Brother Danil", "Andrew Krighton", "Brog Hamfist" },
        ["Dun Morogh"] = { "Adlin Pridedrift", "Kreg Bilmn" }, ["Teldrassil"] = { "Andiss", "Shalomon" },
        ["Durotar"] = { "Duokna" }, ["Mulgore"] = { "Kawnie Softbreeze", "Moorat Longstride" },
        ["Tirisfal Glades"] = { "Joshua Kien", "Mrs. Winters" },
    }
    for zone, names in pairs(need) do
        local z = Q.NPC_ZONES[zone]
        T.ok(z, zone)
        for _, n in ipairs(names) do
            local found
            for _, r in ipairs(z.npcs) do if r[5] == n then found = r end end
            T.ok(found, n .. " in " .. zone)
        end
    end
    for _, c in ipairs({ "Stormwind City", "Ironforge", "Darnassus", "Orgrimmar", "Thunder Bluff", "Undercity" }) do
        local z = Q.NPC_ZONES[c]
        local repair = 0
        for _, r in ipairs(z.npcs) do if string.find(r[4], "R", 1, true) then repair = repair + 1 end end
        T.ok(repair >= 3, c .. " has repairers: " .. repair)
    end
    -- Horde players see no Alliance town's vendors
    local horde = setup({ log = false, name = "Grukk", faction = "Horde" })
    api.tick(horde, 0.3)
    T.eq(horde.Compass.npcIconsShown, 0)
end)

T.test("Quests: NP packets from the realm replace the built-in list; .wnl np on zone change", function()
    local env, Q = setup({ log = false })
    api.connect(env)
    api.fire(env, "ZONE_CHANGED_NEW_AREA")
    api.pump(env)
    T.has(table.concat(env.__wnl, "|"), "np", ".wnl np sent")
    T.has(table.concat(env.__wnl, "|"), "qz", ".wnl qz sent")
    api.server_packet(env, "NP", "12;9001,0.43,0.66,RV,Tess Ironbrand,Weaponsmith;9002,0.42,0.65,F,Rhea;bad;9003,x,y,R,No")
    T.eq(table.getn(Q.serverNpcs["Elwynn Forest"]), 2)
    env.ClassicPlus_Manager:SetSetting("Quests", "trackFlight", true)
    api.tick(env, 0.3)
    T.eq(Q.npcIconsShown, 2, "only the realm's NPCs")
    local tess
    for _, m in ipairs(Q.npcPool) do if m:IsShown() and m.npc.name == "Tess Ironbrand" then tess = m end end
    api.enter(tess)
    T.has(api.tooltip_text(env), "Repairs · Sells weapons")
    T.has(env.Compass_Npc2.tex:GetTexture() .. env.Compass_Npc1.tex:GetTexture(), "Quests_Flight")
end)

-- -- Arrow -----------------------------------------------------------------------------------------------

T.test("Quests: as a ghost the arrow points to your corpse with yards", function()
    local env, Q = setup({ log = false })
    api.set_dead(env, true, 0.4213, 0.7587)          -- dead, not released: lying on the corpse
    api.tick(env, 0.3)
    T.hidden(env.Compass_Arrow, "dead and not released: nothing to point at")
    api.set_dead(env, true, 0.4213, 0.7587, true)    -- released: corpse 10% of Elwynn south, ~231 yards
    api.tick(env, 0.3)
    T.shown(env.Compass_Arrow)
    T.eq(env.Compass_Arrow.title:GetText(), "Your corpse")
    T.has(env.Compass_Arrow.dist:GetText(), "231 yd")
    T.shown(env.Compass_CorpsePin, "corpse marker on the ring")
    -- walking north makes the corpse straight behind you
    env.__map.y = 0.6487
    api.tick(env, 0.3)
    T.near(math.abs(Q.arrowAngle), math.pi, 1e-3, "corpse behind")
    api.set_dead(env, true, nil, nil, true)           -- corpse on another map
    api.tick(env, 0.2)
    T.eq(env.Compass_Arrow.dist:GetText(), "Not on this map")
    api.set_dead(env, false)
    api.tick(env, 1.0)                                -- the arrow fades out rather than blinking off
    T.hidden(env.Compass_Arrow, "alive, nothing tracked with a location: no arrow")
    T.hidden(env.Compass_CorpsePin)
end)

T.test("Quests: the arrow turns with the way you face (the minimap's player arrow), not the way you walked", function()
    local env, Q = setup({ log = false })
    env.__slash("/quests way 52.13 55.87 The Stable")   -- 10% east of where you stand
    T.has(api.chat_text(env), "Arrow set to 52.13, 55.87.")
    env.__map.x, env.__map.y = 0.4213, 0.5587
    api.tick(env, 0.3)
    T.shown(env.Compass_Arrow)
    T.near(Q.arrowAngle, math.pi / 2, 1e-3, "facing north: the target is to your right")
    T.has(env.Compass_Arrow.dist:GetText(), "347 yd")
    api.set_facing(env, -math.pi / 2)                    -- turn to face east (facing turns counter-clockwise)
    api.tick(env, 0.3)
    T.near(Q.arrowAngle, 0, 1e-3, "facing east: straight ahead (the 9th minimap model, not the 8 that never turn)")
    api.set_facing(env, math.pi / 2)                     -- face west
    api.tick(env, 0.3)
    T.near(math.abs(Q.arrowAngle), math.pi, 1e-3, "facing west: behind you")
    env.__map.y = 0.5487                                 -- strafe north while still facing west
    api.tick(env, 0.3)
    T.ok(math.abs(Q.arrowAngle) > 2.3, "walking does not override where you face")
    env.__map.x, env.__map.y = 0.5213, 0.5587            -- arrive
    api.tick(env, 0.2)
    T.eq(env.Compass_Arrow.dist:GetText(), "You are here")
    T.has(table.concat(env.__sounds, " "), "MapPing", "a chime on arrival")
    api.tick(env, 3.5)
    T.eq(Q.waypoint, nil, "a reached waypoint clears itself")
    env.__slash("/quests way nonsense")
    T.has(api.chat_text(env), "Usage: /way")
    env.__slash("/quests arrow")
    T.has(api.chat_text(env), "Waypoint arrow off.")
end)

T.test("Quests: /way and /way clear, and the time to arrive from your walking speed", function()
    local env, Q = setup({ log = false })
    env.__map.x, env.__map.y = 0.4213, 0.5587
    api.set_facing(env, -math.pi / 2)
    env.__slash("/way 52.13, 55.87")
    T.has(api.chat_text(env), "Arrow set to 52.13, 55.87.")
    T.eq(Q.waypoint.title, "Waypoint 52.13, 55.87")
    api.tick(env, 0.6)
    T.lacks(env.Compass_Arrow.dist:GetText(), " s", "standing still: no time shown")
    local step = 7 * 0.5 / 3470                          -- 7 yards a second (run speed) eastward
    for _ = 1, 6 do env.__map.x = env.__map.x + step; api.tick(env, 0.5) end
    T.near(Q:Speed(), 7, 0.6, "run speed measured")
    local d = env.Compass_Arrow.dist:GetText()
    T.has(d, "yd"); T.has(d, " s", "time to arrive shown: " .. d)
    for _ = 1, 4 do api.tick(env, 0.5) end               -- stop
    T.lacks(env.Compass_Arrow.dist:GetText(), " s", "stopped: the time goes away")
    env.__slash("/way clear")
    T.has(api.chat_text(env), "Waypoint cleared.")
    T.eq(Q.waypoint, nil)
    env.__slash("/way")
    T.has(api.chat_text(env), "Usage: /way")
end)

T.test("Quests: Ctrl-click on the world map sets a waypoint there; a plain click is the stock map's", function()
    local env, Q = setup({ log = false })
    env.WorldMapFrame:Show()
    api.set_cursor(env, 501, 434)                       -- the middle of the 1002x668 map
    api.click(env.WorldMapButton, "LeftButton", true)
    T.eq(rawget(env, "__mapClicks"), 1, "a plain click still reaches the stock map (zoom out)")
    T.eq(Q.waypoint, nil)
    env.__keys.ctrl = true
    api.click(env.WorldMapButton, "LeftButton", true)
    env.__keys.ctrl = nil
    T.eq(rawget(env, "__mapClicks"), 1, "Ctrl-click is ours alone")
    T.ok(Q.waypoint, "waypoint set")
    T.near(Q.waypoint.x, 0.5, 1e-6); T.near(Q.waypoint.y, 0.5, 1e-6)
    T.eq(Q.waypoint.zone, Q:MapZoneName())
    T.eq(Q.waypoint.title, "Waypoint 50.0, 50.0")
    api.set_cursor(env, 2000, 434)                      -- off the map
    env.__keys.ctrl = true
    api.click(env.WorldMapButton, "LeftButton", true)
    env.__keys.ctrl = nil
    T.near(Q.waypoint.x, 0.5, 1e-6, "a click off the map changes nothing")
end)

-- -- Tracker --------------------------------------------------------------------------------------------

T.test("Quests: the tracker lists quests with levels, progress and objectives instead of the stock watch", function()
    local env, Q = setup()
    T.shown(env.Compass_Tracker)
    T.ok(env.Compass_Tracker.skinned, "the parchment art is in the repo, so the tracker wears it")
    T.shown(env.Compass_TrackerClose, "the close seal")
    T.ok(api.screen_has(env, "[6] Kobold Camp Cleanup", env.Compass_Tracker))
    T.ok(api.screen_has(env, "- Kobold Vermin: 4/8", env.Compass_Tracker))
    T.ok(api.screen_has(env, "- Ready to turn in", env.Compass_Tracker), "complete quest")
    T.ok(api.screen_has(env, "4/8", env.Compass_Tracker))
    T.ok(api.screen_has(env, "Done", env.Compass_Tracker))
    -- difficulty colours (level 8): 6 yellow, 11 orange, 22 red, 2 grey
    local r = env.Compass_TrackerQuest1
    for i = 1, 8 do
        local row = env["Compass_TrackerQuest" .. i]
        if row and row.key == "Red Silk Bandanas" then r = row end
    end
    local cr, cg = r.label:GetTextColor()
    if env.Compass_Tracker.skinned then
        -- on the parchment the difficulty colours are inked darker; red stays clearly red
        T.near(cr, 0.5, 1e-6); T.near(cg, 0.05, 1e-6, "red: far above you (dark ink)")
    else
        T.near(cr, 1, 1e-6); T.near(cg, 0.1, 1e-6, "red: far above you")
    end
    env.QuestWatchFrame:Show()
    env.AddQuestWatch(2)
    env.QuestWatch_Update()
    T.hidden(env.QuestWatchFrame, "stock watch stays hidden")
    -- current zone first, trackerMax caps the list
    T.eq(env.Compass_TrackerQuest1.key ~= nil and Q.byKey[env.Compass_TrackerQuest1.key].zone, "Elwynn Forest")
    env.ClassicPlus_Manager:SetSetting("Quests", "trackerMax", 3)
    T.ok(api.screen_has(env, "+4 more in the quest log", env.Compass_Tracker))
    env.ClassicPlus_Manager:SetSetting("Quests", "showTracker", false)
    T.hidden(env.Compass_Tracker)
    T.shown(env.QuestWatchFrame, "tracker off: the stock watch comes back")
end)

T.test("Quests: without the parchment art the tracker keeps the plain dark panel", function()
    local env = setup({ art = false })
    T.shown(env.Compass_Tracker)
    T.no(env.Compass_Tracker.skinned, "plain look")
    T.no(env.Compass_TrackerClose, "no close seal")
    T.ok(api.screen_has(env, "- Kobold Vermin: 4/8", env.Compass_Tracker))
    T.ok(api.screen_has(env, "Done", env.Compass_Tracker))
end)

T.test("Quests: tracker clicks pin to the ring, Shift-click untracks, +/- folds objectives", function()
    local env, Q = setup()
    local row
    for i = 1, 8 do
        local r = env["Compass_TrackerQuest" .. i]
        if r and r.key == "Kobold Camp Cleanup" then row = r end
    end
    api.click(row)
    T.eq(Q.pinnedKey, "Kobold Camp Cleanup", "pinned")
    T.has(api.chat_text(env), "No location known for \"Kobold Camp Cleanup\" yet")
    T.eq(env.Compass_TrackerQuest1.key, "Kobold Camp Cleanup", "the pinned quest goes first")
    api.server_packet(env, "CP", "1,0.80,0.66,OBJ,Kobold Camp Cleanup;2,0.81,0.66,OBJ,Wolves Across the Border")
    api.tick(env, 0.2)
    T.eq(Q.arrowTarget.title, "Kobold Camp Cleanup", "the arrow follows the pinned quest")
    api.click(env.Compass_TrackerQuest1)
    T.eq(Q.pinnedKey, nil, "click again to unpin")
    local function rowOf(key)
        for i = 1, 8 do
            local r = env["Compass_TrackerQuest" .. i]
            if r and r:IsShown() and r.key == key then return r end
        end
    end
    api.click(rowOf("Kobold Camp Cleanup").toggle)
    T.no(api.screen_has(env, "- Kobold Vermin: 4/8", env.Compass_Tracker), "folded")
    api.click(rowOf("Kobold Camp Cleanup").toggle)
    T.ok(api.screen_has(env, "- Kobold Vermin: 4/8", env.Compass_Tracker), "unfolded")
    env.__keys.shift = true
    api.click(rowOf("Kobold Camp Cleanup"))
    env.__keys.shift = nil
    T.no(Q:IsTracked("Kobold Camp Cleanup"), "Shift-click untracks")
    T.no(api.screen_has(env, "Kobold Camp Cleanup", env.Compass_Tracker))
    api.click(env.Compass_TrackerQuest1, "RightButton")
    T.shown(env.WenillaCore_Menu, "right-click menu")
end)

T.test("Quests: progress, objective and quest completion: chimes, banner, learned spot, auto-track", function()
    local env, Q = setup()
    local e = api.quest(env, "Kobold Camp Cleanup")
    e.objectives[1].text = "Kobold Vermin slain: 5/8"
    api.fire(env, "QUEST_LOG_UPDATE")
    api.tick(env, 0.3)
    T.ok(api.screen_has(env, "- Kobold Vermin: 5/8", env.Compass_Tracker), "live progress")
    T.ok(Q:DB().learned["Kobold Camp Cleanup"], "the spot was remembered")
    T.ok(Q:BestNode("Kobold Camp Cleanup"), "a learned objective node")
    e.objectives[1].text = "Kobold Vermin slain: 8/8"
    e.objectives[1].done = true
    e.complete = 1
    api.fire(env, "QUEST_LOG_UPDATE")
    api.tick(env, 0.3)
    T.has(table.concat(env.__sounds, " "), "igQuestListComplete")
    T.ok(api.screen_has(env, "Quest complete"), "banner")
    -- a new quest is tracked automatically
    table.insert(env.__questlog, 2, { title = "Princess Must Die!", level = 9, objectives = { { text = "Princess slain: 0/1", type = "monster" } } })
    api.fire(env, "QUEST_LOG_UPDATE")
    api.tick(env, 0.3)
    T.ok(Q:IsTracked("Princess Must Die!"))
    T.ok(api.screen_has(env, "Princess Must Die!", env.Compass_Tracker))
end)

-- -- Tooltips ----------------------------------------------------------------------------------------------

T.test("Quests: mob and item tooltips show quest progress", function()
    local env = setup()
    api.mouseover(env, { name = "Kobold Vermin", isPlayer = false, hostile = true, level = 3 })
    local tip = api.tooltip_text(env)
    T.has(tip, "Kobold Camp Cleanup")
    T.has(tip, "Kobold Vermin: 4/8")
    api.mouseover(env, { name = "Defias Thug", isPlayer = false, hostile = true })
    T.lacks(api.tooltip_text(env), "Kobold")
    api.add_item(env, 750, { name = "Tough Wolf Meat", quality = 1, icon = "Interface\\Icons\\INV_Misc_Food_14" })
    local slot = api.give_item(env, 750, 2)
    env.GameTooltip:SetOwner(env.UIParent, "ANCHOR_NONE")
    env.GameTooltip:SetBagItem(0, slot)
    T.has(api.tooltip_text(env), "Tough Wolf Meat: 2/8")
    env.ClassicPlus_Manager:SetSetting("Quests", "tooltips", false)
    env.GameTooltip:SetBagItem(0, slot)
    T.lacks(api.tooltip_text(env), "2/8", "the option turns it off")
end)

-- -- The quest log -------------------------------------------------------------------------------------------

local function rowsText(env)
    local out = {}
    for _, row in ipairs(env.Compass_LogList.rows) do
        if row:IsShown() then
            table.insert(out, api.visible((row.level:GetText() or "") .. " " .. (row.title:GetText() or "") .. " | " .. (row.right:GetText() or "")))
        end
    end
    return table.concat(out, "\n")
end

T.test("Quests: L, the micro button and the stock frame open our quest log; the classic one is a setting away", function()
    local env, Q = setup()
    env.ToggleQuestLog()
    T.shown(env.Compass_Log, "L opens ours")
    T.hidden(env.QuestLogFrame)
    env.ToggleQuestLog()
    T.hidden(env.Compass_Log, "L again closes it")
    api.click(env.QuestLogMicroButton)
    T.shown(env.Compass_Log, "micro menu quest button")
    T.ok(api.press_escape(env))
    T.hidden(env.Compass_Log, "Escape closes it")
    env.QuestLogFrame:Show()
    T.hidden(env.QuestLogFrame, "the stock frame hands over")
    T.shown(env.Compass_Log)
    env.Compass_Log:Hide()
    env.ClassicPlus_Manager:SetSetting("Quests", "replaceLog", false)
    env.ToggleQuestLog()
    T.shown(env.QuestLogFrame, "setting off: the classic log")
    T.hidden(env.Compass_Log)
    env.QuestLogFrame:Hide()
    env.ClassicPlus_Manager:SetSetting("Quests", "replaceLog", true)
    Q.Log:Open()
    Q.Log:SetPage("options")
    api.click(env.Compass_LogClassic)
    T.shown(env.QuestLogFrame, "Options: open the classic log once")
end)

T.test("Quests: the log groups by zone with levels, tags, progress and status marks", function()
    local env, Q = setup()
    Q.Log:Open()
    local rows = rowsText(env)
    T.has(rows, "Elwynn Forest | 4", "current zone first, with its count")
    T.has(rows, "[6] Kobold Camp Cleanup | 4/8")
    T.has(rows, "[22] Red Silk Bandanas  Dungeon | 0/10")
    T.has(rows, "[10] Taming the Beast  Elite, Class |", "class quest under the class header")
    T.has(rows, "[5] Report to Goldshire | Done")
    T.ok(string.find(rows, "Elwynn Forest", 1, true) < string.find(rows, "Westfall", 1, true))
    T.eq(Q.Log.count:GetText(), "7/20", "quest count")
    -- fold a zone
    api.click_text(env, "Westfall", env.Compass_Log)
    T.lacks(rowsText(env), "Red Silk Bandanas", "folded")
    api.click_text(env, "Westfall", env.Compass_Log)
    T.has(rowsText(env), "Red Silk Bandanas", "unfolded")
    -- a collapsed stock header does not hide quests from us
    local env2 = setup({ name = "Ilyndra", log = { { header = "Duskwood", collapsed = true }, { title = "Look to the Stars", level = 24, objectives = {} } } })
    T.ok(env2.Compass.byKey["Look to the Stars"], "collapsed headers are expanded to read the quests")
end)

T.test("Quests: search, filters, hide grey and sorting", function()
    local env, Q = setup()
    Q.Log:Open()
    api.type(env.Compass_LogSearch, "wolf")
    local rows = rowsText(env)
    T.has(rows, "Wolves Across the Border"); T.lacks(rows, "Kobold Camp")
    api.type(env.Compass_LogSearch, "vermin")
    T.has(rowsText(env), "Kobold Camp Cleanup", "search finds objective text")
    api.type(env.Compass_LogSearch, "")
    api.click(env.Compass_LogFilter)
    api.click_text(env, "Only complete", env.WenillaCore_Menu)
    rows = rowsText(env)
    T.has(rows, "Report to Goldshire"); T.lacks(rows, "Kobold Camp")
    T.eq(env.Compass_LogFilter.text, "Filter (1)")
    api.click(env.Compass_LogFilter)
    api.click_text(env, "Only complete", env.WenillaCore_Menu)
    api.click(env.Compass_LogFilter)
    api.click_text(env, "Dungeons and raids", env.WenillaCore_Menu)
    rows = rowsText(env)
    T.has(rows, "Red Silk Bandanas"); T.lacks(rows, "Report to Goldshire")
    Q:Set("filterDungeon", false)
    api.click(env.Compass_LogFilter)
    api.click_text(env, "Group quests", env.WenillaCore_Menu)
    rows = rowsText(env)
    T.has(rows, "Taming the Beast"); T.has(rows, "Red Silk"); T.lacks(rows, "Kobold")
    Q:Set("filterGroup", false)
    api.click(env.Compass_LogFilter)
    api.click_text(env, "Only this zone", env.WenillaCore_Menu)
    T.lacks(rowsText(env), "Westfall")
    Q:Set("filterZone", false)
    api.click(env.Compass_LogFilter)
    api.click_text(env, "Hide grey quests", env.WenillaCore_Menu)
    T.lacks(rowsText(env), "Lost Necklace", "grey quest hidden")
    Q:Set("hideGrey", false)
    -- sorting
    api.click(env.Compass_LogSort)
    api.click_text(env, "Level", env.WenillaCore_Menu)
    rows = rowsText(env)
    T.lacks(rows, "Elwynn Forest |", "no zone headers when sorted by level")
    T.ok(string.find(rows, "[2] Lost", 1, true) < string.find(rows, "[22] Red", 1, true), "low to high")
    T.eq(env.Compass_LogSort.text, "Sort: Level")
    api.click(env.Compass_LogSort)
    api.click_text(env, "Progress", env.WenillaCore_Menu)
    rows = rowsText(env)
    T.ok(string.find(rows, "Report to Goldshire", 1, true) < string.find(rows, "Kobold Camp", 1, true), "complete first")
    T.ok(string.find(rows, "Kobold Camp", 1, true) < string.find(rows, "Red Silk", 1, true), "4/8 before 0/10")
    api.server_packet(env, "CP", "1,0.43,0.66,OBJ,Red Silk Bandanas;2,0.9,0.9,OBJ,Kobold Camp Cleanup")
    api.click(env.Compass_LogSort)
    api.click_text(env, "Distance", env.WenillaCore_Menu)
    rows = rowsText(env)
    T.ok(string.find(rows, "Red Silk", 1, true) < string.find(rows, "Kobold Camp", 1, true), "nearest first")
end)

T.test("Quests: the detail pane: description, objective bars, rewards with an upgrade arrow, money", function()
    local env, Q = setup({ items = {
        [1203] = { name = "Aegis of Stormwind", quality = 3, icon = "Interface\\Icons\\INV_Shield_06", lines = { "Off Hand", "1100 Armor", "+8 Stamina" } },
        [6125] = { name = "Old Shield", quality = 1, icon = "Interface\\Icons\\INV_Shield_04", lines = { "Off Hand", "80 Armor" } },
    } })
    env.__inventory[17] = 6125
    Q.Log:Open("Kobold Camp Cleanup")
    local body = env.Compass_LogDetailBody
    T.ok(api.screen_has(env, "Kobold Camp Cleanup", body))
    T.ok(api.screen_has(env, "Level 6 · Elwynn Forest", body))
    T.ok(api.screen_has(env, "Clear the kobolds out of the camp", body))
    T.ok(api.screen_has(env, "Kill 8 Kobold Vermin.", body))
    T.ok(api.screen_has(env, "Kobold Vermin", body))
    local bar = body and Q.Log.body
    T.ok(api.screen_has(env, "Choose one of:", body))
    T.ok(api.screen_has(env, "Aegis of Stormwind", body))
    T.ok(api.screen_has(env, "You will also receive:", body))
    T.ok(api.screen_has(env, "Red Linen Shirt", body))
    T.ok(api.screen_has(env, "2s 50c", body), "money")
    local aegis
    for i = 1, 3 do
        local b = env["Compass_LogReward" .. i]
        if b and b.itemName == "Aegis of Stormwind" then aegis = b end
    end
    T.shown(aegis.up, "upgrade arrow over the equipped shield")
    api.enter(aegis)
    T.has(api.tooltip_text(env), "Upgrade over Old Shield")
    T.eq(env.Compass_LogBtn1.text, "Untrack")
    T.eq(env.Compass_LogBtn4.text, "Abandon")
    api.click(env.Compass_LogBtn1)
    T.no(Q:IsTracked("Kobold Camp Cleanup"))
    T.eq(env.Compass_LogBtn1.text, "Track")
    -- auto-pick marks the best choice
    env.ClassicPlus_Manager:SetSetting("Quests", "autoPick", true)
    Q.Log:Refresh()
    T.shown(aegis.best, "best reward marked")
end)

T.test("Quests: abandon asks, then gives 10 seconds to undo; afterwards it is in the history", function()
    local env, Q = setup()
    Q.Log:Open("Wolves Across the Border")
    api.click(env.Compass_LogBtn4)
    T.has(env.__popups[1].text, "Abandon \"Wolves Across the Border\"?")
    api.popup_click(env, "COMPASS_ABANDON", 1)
    api.tick(env, 0.3)
    T.shown(env.Compass_LogUndo, "undo strip")
    T.ok(api.screen_has(env, "Abandoning \"Wolves Across the Border\"", env.Compass_LogUndo))
    T.has(rowsText(env), "Wolves Across the Border | Abandoning")
    api.click(env.Compass_LogUndoButton)
    T.has(api.chat_text(env), "Kept \"Wolves Across the Border\".")
    api.tick(env, 11)
    T.ok(Q.byKey["Wolves Across the Border"], "undone: still in the log")
    T.eq(table.getn(env.__abandoned), 0)
    api.click(env.Compass_LogBtn4)
    api.popup_click(env, "COMPASS_ABANDON", 1)
    api.tick(env, 9)
    T.ok(Q.byKey["Wolves Across the Border"], "not yet")
    api.tick(env, 1.5)
    T.eq(env.__abandoned[1], "Wolves Across the Border", "abandoned after 10 s")
    T.eq(Q.byKey["Wolves Across the Border"], nil)
    local h = Q:DB().history[1]
    T.eq(h.title, "Wolves Across the Border"); T.eq(h.how, "abandoned")
    api.click_text(env, "Completed", env.Compass_Log)
    T.has(rowsText(env), "Wolves Across the Border")
    T.ok(api.screen_has(env, "Abandoned.", env.Compass_LogDetailBody))
    T.ok(api.screen_has(env, "The game cannot put an abandoned quest back", env.Compass_LogDetailBody), "explains how to get it again")
end)

T.test("Quests: abandon all grey quests in one go, with the same undo", function()
    local env, Q = setup()
    Q.Log:Open()
    api.click(env.Compass_LogFilter)
    api.click_text(env, "Abandon all grey quests (1)...", env.WenillaCore_Menu)
    T.has(env.__popups[1].text, "Abandon 1 grey quests?")
    api.popup_click(env, "COMPASS_ABANDON_GREYS", 1)
    api.tick(env, 10.5)
    T.eq(env.__abandoned[1], "Lost Necklace")
end)

T.test("Quests: turned-in quests go to the dated, searchable Completed tab", function()
    local env, Q = setup()
    api.quest_npc(env, { title = "Report to Goldshire" })
    env.GetQuestReward(nil)
    api.tick(env, 0.3)
    T.eq(Q:DB().history[1].how, "done")
    Q.Log:Open()
    Q.Log:SetPage("history")
    T.has(rowsText(env), "Report to Goldshire")
    T.ok(api.screen_has(env, "Turned in.", env.Compass_LogDetailBody))
    api.type(env.Compass_LogSearch, "kobold")
    T.lacks(rowsText(env), "Report to Goldshire", "search works on the history")
    -- the history survives a relog
    local env2 = T.relog(env)
    T.eq(env2.Compass:DB().history[1].title, "Report to Goldshire")
end)

T.test("Quests: keys move the selection, Enter tracks, Escape closes; Shift-click links", function()
    local env, Q = setup()
    Q.Log:Open()
    local first = Q.Log.selected
    T.eq(first, "Lost Necklace", "the first quest is selected")
    api.run_script(env.Compass_Log, "OnKeyDown", { "DOWN" })
    T.eq(Q.Log.selected, "Report to Goldshire", "level order inside the zone")
    api.run_script(env.Compass_Log, "OnKeyDown", { "UP" })
    T.eq(Q.Log.selected, first)
    api.run_script(env.Compass_Log, "OnKeyDown", { "ENTER" })
    T.no(Q:IsTracked(first), "Enter toggles tracking")
    env.ChatFrameEditBox:Show()
    env.__keys.shift = true
    api.click_text(env, "Wolves Across the Border", env.Compass_Log)
    env.__keys.shift = nil
    T.eq(env.ChatFrameEditBox:GetText(), "[Wolves Across the Border]")
    api.run_script(env.Compass_Log, "OnKeyDown", { "ESCAPE" })
    T.hidden(env.Compass_Log)
end)

T.test("Quests: Share pushes the quest and collects the party's replies", function()
    local env, Q = setup({ party = { { name = "Brakkus", class = "WARRIOR" } } })
    Q.Log:Open("Kobold Camp Cleanup")
    api.click(env.Compass_LogBtn3)
    T.eq(env.__pushed, "Kobold Camp Cleanup")
    api.fire(env, "CHAT_MSG_SYSTEM", "Brakkus has accepted your quest")
    T.ok(api.screen_has(env, "Shared: Brakkus accepted", env.Compass_Log))
    -- alone: explained, nothing sent
    local solo = setup({ name = "Solo" })
    solo.Compass:Share("Kobold Camp Cleanup")
    T.has(api.chat_text(solo), "You need to be in a party to share a quest.")
end)

T.test("Quests: party members see each other's progress on shared quests", function()
    local a = setup({ name = "Herald" })
    local b = setup({ name = "Brakkus" })
    api.group({ a, b }, "party")
    api.tick(a, 0.3)
    local e = api.quest(b, "Kobold Camp Cleanup")
    e.objectives[1].text = "Kobold Vermin slain: 6/8"
    api.fire(b, "QUEST_LOG_UPDATE")
    api.tick(b, 0.3)
    local p = a.Compass:PartyProgress("Kobold Camp Cleanup")
    T.eq(p[1] and p[1].name, "Brakkus")
    T.eq(p[1].text, "6/8")
    a.Compass.Log:Open("Kobold Camp Cleanup")
    T.ok(api.screen_has(a, "Brakkus: 6/8", a.Compass_LogDetailBody))
end)

T.test("Quests: realm extras: nearby quests tab (QZ), chains and turn-in NPC (QM)", function()
    local env, Q = setup()
    Q.Log:Open()
    T.eq(Q.Log.tabs:Button("nearby"), nil, "no Nearby tab without realm data")
    api.server_packet(env, "QZ", "12;33,0.44,0.66,6,4,Marshal Dughan,A Fishy Peril;34,0.9,0.9,12,10,Remy,Bounty, the Big One")
    T.ok(Q.Log.tabs:Button("nearby"), "Nearby tab appears")
    Q.Log:SetPage("nearby")
    local rows = rowsText(env)
    T.has(rows, "[6] A Fishy Peril")
    T.has(rows, "Bounty, the Big One")
    T.ok(string.find(rows, "Fishy", 1, true) < string.find(rows, "Bounty", 1, true), "nearest first")
    T.ok(api.screen_has(env, "Marshal Dughan, Elwynn Forest (44, 66)", env.Compass_LogDetailBody))
    api.click(env.Compass_LogBtn1)
    T.eq(Q.waypoint.title, "A Fishy Peril")
    api.server_packet(env, "QM", "40,2,4,450,0.42,0.66,12,Marshal Dughan,Report to Goldshire")
    Q.Log:Open("Report to Goldshire")
    T.ok(api.screen_has(env, "Part 2 of 4", env.Compass_LogDetailBody))
    T.ok(api.screen_has(env, "Turn in: Marshal Dughan, Elwynn Forest (42, 66)", env.Compass_LogDetailBody))
    T.ok(api.screen_has(env, "450 experience", env.Compass_LogDetailBody))
    local n = Q:BestNode("Report to Goldshire")
    T.eq(n.type, "TURNIN", "a turn-in node for the complete quest")
    T.ok(api.screen_has(env, "Ready to turn in to Marshal Dughan", env.Compass_Tracker))
end)

T.test("Quests: auto turn-in is off by default; with auto-pick it takes the best reward", function()
    local env, Q = setup({ items = {
        [1203] = { name = "Aegis of Stormwind", quality = 3, icon = "x", lines = { "Off Hand", "1100 Armor" } },
    } })
    api.quest_npc(env, { title = "Kobold Camp Cleanup", complete = true, choices = { { id = 858 }, { id = 1203 } } }, "QUEST_COMPLETE")
    T.eq(table.getn(env.__rewards), 0, "off by default")
    env.ClassicPlus_Manager:SetSetting("Quests", "autoTurnIn", true)
    api.fire(env, "QUEST_COMPLETE")
    T.eq(table.getn(env.__rewards), 0, "several rewards and no auto-pick: left to you")
    T.has(api.chat_text(env), "has 2 rewards to choose from")
    env.ClassicPlus_Manager:SetSetting("Quests", "autoPick", true)
    api.fire(env, "QUEST_COMPLETE")
    T.eq(env.__rewards[1].choice, 2, "the shield is the upgrade")
    T.has(api.chat_text(env), "took Aegis of Stormwind")
    api.quest_npc(env, { title = "Report to Goldshire", complete = true }, "QUEST_PROGRESS")
    T.eq(env.__completed_quests[1], "Report to Goldshire", "progress page continued")
end)

T.test("Quests: schema and Options page cover every option", function()
    local env, Q = setup()
    local schema = env.WenillaCore.schemas.Quests
    T.ok(schema, "schema registered")
    T.eq(table.getn(schema.options), table.getn(Q.OPTIONS))
    local keys = {}
    for _, o in ipairs(schema.options) do keys[o.key] = true end
    for _, k in ipairs({ "showRing", "replaceBorder", "ringTheme", "trackRepair", "trackSell", "trackFlight", "trackInn",
        "trackTrainer", "trackBank", "showArrow", "corpseArrow", "showTracker", "replaceLog", "hideGrey", "autoPick",
        "autoTurnIn", "chimes", "tooltips", "groupProgress", "worldMapPins" }) do
        T.ok(keys[k], "option " .. k)
        T.ok(schema.defaults[k] ~= nil, "default for " .. k)
    end
    T.eq(schema.defaults.trackRepair, true); T.eq(schema.defaults.trackSell, true); T.eq(schema.defaults.autoTurnIn, false)
    env.__slash("/quests options")
    T.shown(env.Compass_LogOptions)
    T.hidden(env.Compass_LogList)
    api.click(env.Compass_Opt_chimes)
    T.eq(Q:Get("chimes"), false)
    api.click(env.Compass_Opt_ringTheme)
    T.eq(Q:Get("ringTheme"), "stone")
    T.has(env.Compass_RingTexture:GetTexture(), "CompassRing_Stone")
    api.click(env.Compass_Opt_trackerMax)
    T.eq(Q:Get("trackerMax"), 12)
end)

T.test("Quests: slash commands and switching the addon off", function()
    local env, Q = setup()
    env.__slash("/quests")
    T.shown(env.Compass_Log)
    env.__slash("/quests")
    T.hidden(env.Compass_Log)
    env.__slash("/quests completed")
    T.eq(Q.Log.page, "history")
    env.__slash("/quests tracker")
    T.hidden(env.Compass_Tracker)
    env.__slash("/quests help")
    T.has(api.chat_text(env), "/quests way 42 65")
    env.WenillaCore:SetAddonEnabled("Quests", false)
    T.hidden(env.Compass_RingFrame)
    T.hidden(env.Compass_Log)
    T.shown(env.MinimapBorder)
    env.ToggleQuestLog()
    T.shown(env.QuestLogFrame, "addon off: the classic log")
    env.__slash("/quests")
    T.has(api.chat_text(env), "Quests is switched off")
end)

T.test("Quests: CP titles cut to 48 characters still find their quest", function()
    local long = "The Collector of Very Long Quest Titles in Westfall, Part One"
    local env, Q = setup({ log = { { header = "Elwynn Forest" }, { title = long, level = 8, objectives = { { text = "Harvest Golem slain: 1/8", type = "monster" } } } } })
    api.server_packet(env, "CP", "9,0.9,0.9,OBJ," .. string.sub(long, 1, 48))
    local n = Q:BestNode(long)
    T.ok(n, "the node belongs to the quest")
    T.eq(n.title, long)
end)

T.test("Quests: a UI repack that takes the ring off the minimap keeps its own minimap layout", function()
    local env, Q = setup({ log = false })
    -- what Repack's square minimap does: hide the stock pieces, park the ring
    local hidden = env.CreateFrame("Frame")
    hidden:Hide()
    env.MinimapBorder:Hide()
    env.MinimapZoomIn:Hide()
    env.Compass_RingFrame:SetParent(hidden)
    env.ClassicPlus_Manager:SetSetting("Quests", "showRing", false)
    T.hidden(env.MinimapBorder, "the repack's hidden border stays hidden")
    env.WenillaCore:SetAddonEnabled("Quests", false)
    T.hidden(env.MinimapBorder, "even with Quests off")
end)
