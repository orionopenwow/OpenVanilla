-- Dungeons: the group finder board between clients over the hidden OWDungeons channel - listing,
-- browsing, ask to join (a whisper), the leader's Invite (InviteByName), endorsements, recent
-- runs, getting there, expiry, ignore and the level filter.
local T, api = ...

local function client(name, opts)
    opts = opts or {}
    opts.name = name
    return T.addon("Dungeons", opts)
end

-- Brakkus (22 warrior, in a party: lists a group) and Herald (19 hunter, solo)
local function two(aOpts, bOpts)
    local A = client("Brakkus", aOpts or { class = "WARRIOR", level = 22, party = { { name = "Saria", class = "PRIEST", level = 21 } },
        map = { x = 0.5, y = 0.5, zone = "Westfall" } })
    local B = client("Herald", bOpts or { class = "HUNTER", level = 19, map = { x = 0.4, y = 0.6, zone = "Elwynn Forest" } })
    api.tick(A, 9)       -- both join OWDungeons 8 s after entering the world
    return A, B
end

local function pick(env, dungeonName)
    for i = 1, 12 do
        local row = env["Dungeons_Pick" .. i]
        if row and row:IsVisible() and row.item and row.item.name == dungeonName then
            if not env.Dungeons.DB().prefs.dungeons[row.item.key] then api.click(row) end
            return row
        end
    end
    error("no pick row for " .. dungeonName)
end

-- open My Listing, tick a dungeon, set a role and note, List
local function list(env, dungeonName, role, note, meet)
    env.__slash("/lfg list")
    T.shown(env.Dungeons_Frame, "window")
    pick(env, dungeonName)
    if role then
        local roles = env.Dungeons.DB().prefs.roles
        for k in pairs(roles) do roles[k] = nil end
        roles[role] = true
    end
    api.type(env.Dungeons_Note, note or "")
    api.type(env.Dungeons_Meet, meet or "")
    api.click(env.Dungeons.mine.listBtn)
    api.tick(env, 2)
end

local function board(env)
    env.__slash("/lfg browse")
    T.shown(env.Dungeons_Frame)
    return env.Dungeons.browser
end

T.test("Dungeons: a group listing appears on another client's board", function()
    local A, B = two()
    T.ok(A.GetChannelName("OWDungeons") > 0, "A joined the hidden channel")
    T.ok(B.GetChannelName("OWDungeons") > 0, "B joined the hidden channel")
    list(A, "The Deadmines", "h", "Need a healer, then we go", "Moonbrook inn")
    T.ok(A.Dungeons:MyListing(), "A is listed")
    board(B)
    local row = B.Dungeons_BoardRow1
    T.shown(row, "first card")
    T.has(api.visible(row.name:GetText()), "Brakkus  22 Warrior")
    T.has(api.visible(row.info:GetText()), "The Deadmines")
    T.has(api.visible(row.info:GetText()), "Need a healer, then we go")
    T.has(api.visible(row.info:GetText()), "Westfall")
    T.eq(row.act:GetText(), "Ask to join", "groups get Ask to join")
    T.eq(row.size:GetText(), "group 2/5")
    T.ok(api.screen_has(B, "0 players", B.Dungeons_Frame) and api.screen_has(B, "1 group", B.Dungeons_Frame), "count")
    -- hover: the details
    api.enter(row)
    local tip = api.tooltip_text(B)
    T.has(tip, "Level 22 Warrior")
    T.has(tip, "Healer needed")
    T.has(tip, "Group of 2/5")
    T.has(tip, "Meet at: Moonbrook inn")
    -- the carrier never shows in chat
    T.lacks(api.chat_text(A), "OWDungeons")
    T.lacks(api.chat_text(B), "OWDungeons")
    T.lacks(api.chat_text(B), "!L ")
end)

T.test("Dungeons: Ask to join whispers the leader, whose Invite sends a normal invite", function()
    local A, B = two()
    list(A, "The Deadmines", "h", "Need a healer")
    board(B)
    api.click(B.Dungeons_BoardRow1.act)
    api.pump(B)
    T.has(api.chat_text(A), "[Herald] whispers: [Dungeons] Herald, 19 Hunter, damage, wants The Deadmines")
    T.eq(B.Dungeons_BoardRow1.act:GetText(), "Asked")
    T.eq(#B.__invites, 0, "asking never invites or teleports anyone")
    -- a second ask within a minute is held back
    local sent = #B.__chat_sent
    api.click(B.Dungeons_BoardRow1.act)
    T.eq(#B.__chat_sent, sent, "no repeat whisper")
    -- the leader sees the request with an Invite button
    T.eq(A.Dungeons.requests[1].name, "Herald")
    T.eq(A.Dungeons.requests[1].dungeon.key, "dm")
    T.ok(api.screen_has(A, "Herald wants to join"), "a toast for the request")
    A.__slash("/lfg list")
    local req = A.Dungeons_Request1
    T.shown(req, "request row")
    T.has(api.visible(req.text:GetText()), "Herald  19 Hunter, damage  The Deadmines")
    api.click(req.invite)
    api.pump(A)
    T.eq(A.__invites[1], "Herald", "InviteByName")
    T.eq(req.invite:GetText(), "Invited")
    local got = false
    for _, e in ipairs(B.__events_fired) do if e == "PARTY_INVITE_REQUEST" then got = true end end
    T.ok(got, "Herald got the stock invite")
    -- Decline drops it
    api.click(req.decline)
    T.eq(#A.Dungeons.requests, 0)
end)

T.test("Dungeons: a solo player's card has Invite; the role list follows the class", function()
    local A, B = two()
    B.__slash("/lfg list")
    local roles = B.Dungeons.mine.roles
    api.click(roles.t)
    T.no(B.Dungeons.DB().prefs.roles.t, "a hunter cannot list as a tank")
    list(B, "Wailing Caverns", nil, "Pet tanking practice")
    board(A)
    local row = A.Dungeons_BoardRow1
    T.has(api.visible(row.name:GetText()), "Herald  19 Hunter")
    T.eq(row.act:GetText(), "Invite")
    T.ok((row.size:GetText() or "") == "", "no group size on a player card")
    api.click(row.act)
    T.eq(A.__invites[1], "Herald")
    T.eq(row.act:GetText(), "Invited")
    -- the lister's own card is marked and has no buttons
    board(B)
    T.hidden(B.Dungeons_BoardRow1.act, "no button on your own card")
end)

T.test("Dungeons: dungeons fit your level; Show all lists every raid", function()
    local A = client("Herald", { class = "HUNTER", level = 19 })
    A.__slash("/lfg list")
    local names = {}
    for _, d in ipairs(A.Dungeons.mine.list.items) do names[d.name] = true end
    T.ok(names["The Deadmines"] and names["Wailing Caverns"] and names["Ragefire Chasm"], "level 19 fits RFC, WC, DM")
    T.no(names["Molten Core"], "Molten Core is not for level 19")
    T.no(names["Scholomance"])
    T.ok(api.screen_has(A, "DUNGEONS FOR LEVEL 19", A.Dungeons_Frame))
    api.click(A.Dungeons.mine.showAll)
    names = {}
    for _, d in ipairs(A.Dungeons.mine.list.items) do names[d.name] = true end
    T.ok(names["Molten Core"] and names["Naxxramas"], "Show all")
    T.eq(#A.Dungeons.mine.list.items, 32, "every 1.12 dungeon and raid")
    -- level ranges
    local D = A.Dungeons
    T.eq(D.BY_KEY.rfc.min .. "-" .. D.BY_KEY.rfc.max, "13-18")
    T.eq(D.BY_KEY.wc.min .. "-" .. D.BY_KEY.wc.max, "17-24")
    T.eq(D.BY_KEY.dm.min .. "-" .. D.BY_KEY.dm.max, "17-26")
    T.eq(D.BY_KEY.mc.min, 60)
    -- nothing picked: listing refuses
    api.click(A.Dungeons.mine.listBtn)
    T.no(A.Dungeons:MyListing())
    T.has(api.chat_text(A), "pick at least one dungeon")
end)

T.test("Dungeons: Getting there shows the entrance and opens the map on its zone", function()
    local A, B = two()
    list(A, "The Deadmines", "h", "", "Moonbrook inn")
    local b = board(B)
    api.click(B.Dungeons_BoardRow1)
    local tr = b.travelFrame
    T.has(api.visible(tr.head:GetText()), "The Deadmines  17-26")
    T.has(tr.body:GetText(), "Entrance: Westfall 42.6, 71.8")
    T.has(tr.body:GetText(), "Meeting stone near the entrance")
    T.has(tr.body:GetText(), "Meet at: Moonbrook inn")
    api.click(api.find_button(B, "Show on map", B.Dungeons_Frame))
    T.shown(B.WorldMapFrame, "world map")
    T.eq(B.__map_zoom[1], 2, "Eastern Kingdoms")
    T.eq(B.__map_zoom[2], 24, "Westfall")
    T.has(api.chat_text(B), "The Deadmines entrance - Westfall 42.6, 71.8")
    -- with the Quests waypoint arrow, "Pin it" points it at the entrance
    if not B.Compass or not B.Compass.SetWaypoint then
        T.hidden(tr.pin, "no pin button without a waypoint API")
        B.Compass = B.Compass or {}
        B.Compass.SetWaypoint = function(self, t) self.__wp = t end
    end
    local set = B.Compass.SetWaypoint
    B.Compass.SetWaypoint = function(self, t) self.__wp = t; return set(self, t) end
    B.Dungeons:Refresh()
    T.shown(tr.pin, "Pin it")
    api.click(tr.pin)
    T.eq(B.Compass.__wp.zone, "Westfall")
    T.near(B.Compass.__wp.x, 0.426, 1e-6)
    T.eq(B.Compass.__wp.title, "The Deadmines entrance")
    -- Blackrock Mountain dungeons say where the stone is
    T.has(select(2, B.Dungeons:TravelText(B.Dungeons.BY_KEY.mc)), "Meeting stone inside Blackrock Mountain")
end)

T.test("Dungeons: grouping fills Recent; Endorse counts on the board and in Recent", function()
    local A, B = two()
    list(A, "The Deadmines", "h", "")
    A.__map.zone, B.__map.zone = "The Deadmines", "The Deadmines"
    api.group({ A, B }, "party")
    api.tick(A, 1)
    T.eq(B.Dungeons.DB().recent[1].name, "Brakkus")
    T.eq(B.Dungeons.DB().recent[1].dungeon, "dm")
    B.__slash("/lfg recent")
    local row = B.Dungeons_Recent1
    T.shown(row)
    T.has(api.visible(row.name:GetText()), "Brakkus  22 Warrior")
    T.has(api.visible(row.info:GetText()), "The Deadmines")
    api.click(row.endorse)
    api.tick(B, 2)
    T.eq(row.endorse:GetText(), "Endorsed")
    T.no(row.endorse:IsEnabled(), "once per run")
    T.eq(A.Dungeons.DB().endorse.count, 1)
    T.has(api.chat_text(A), "Herald endorsed you")
    -- a second endorsement from the same player the same day does not count
    A.Dungeons:Endorsed("Herald")
    T.eq(A.Dungeons.DB().endorse.count, 1)
    -- A re-broadcasts with the count; B's board and Recent show it
    api.tick(A, 3)
    T.eq(B.Dungeons:EndorseCount("Brakkus"), 1)
    T.eq(row.stars:GetText(), "1")
    board(B)
    T.eq(B.Dungeons_BoardRow1.stars:GetText(), "1")
    -- Recent survives a relog
    B = T.relog(B)
    T.eq(B.Dungeons.DB().recent[1].name, "Brakkus")
end)

T.test("Dungeons: the ignore list hides listings and requests", function()
    local A, B = two()
    A.AddIgnore("Herald")
    list(B, "The Deadmines", "d", "hi")
    board(A)
    T.hidden(A.Dungeons_BoardRow1, "an ignored player's card")
    T.eq(A.Dungeons.listings.Herald, nil, "not even stored")
    list(A, "The Deadmines", "h", "")
    A.Dungeons:OnWhisper("[Dungeons] Herald, 19 Hunter, damage, wants The Deadmines", "Herald")
    T.eq(#A.Dungeons.requests, 0, "no request from an ignored player")
end)

T.test("Dungeons: a listing lapses 30 minutes after you go idle, renews while you move", function()
    local A, B = two()
    list(A, "The Deadmines", "h", "")
    board(B)
    T.shown(B.Dungeons_BoardRow1)
    -- moving keeps it up: 40 minutes, a step every minute
    for i = 1, 40 do
        A.__map.x = 0.5 + i / 1000
        api.tick(A, 60, 1)
    end
    T.ok(A.Dungeons:MyListing(), "still listed while active")
    B.Dungeons:Refresh()
    T.shown(B.Dungeons_BoardRow1, "renewed on B's board")
    -- standing still: gone after 30 minutes, with a note in chat and on B's board
    api.tick(A, 31 * 60, 1)
    T.no(A.Dungeons:MyListing(), "lapsed")
    T.has(api.chat_text(A), "your listing ran out")
    T.eq(B.Dungeons.listings.Brakkus, nil, "removed from B's board")
end)

T.test("Dungeons: other players' text is shown literally; bad lines are ignored", function()
    local A, B = two()
    list(A, "The Deadmines", "h", "|cffff0000free|r gold ~ at the bank")
    board(B)
    local l = B.Dungeons.listings.Brakkus
    T.eq(l.note, "|cffff0000free|r gold ~ at the bank", "decoded")
    T.has(B.Dungeons_BoardRow1.info:GetText(), "||cffff0000free||r gold ~ at the bank")
    -- malformed or hostile lines do nothing
    local id = A.GetChannelName("OWDungeons")
    for _, line in ipairs({ "!L", "!L x 1/1 abc", "!L 5 9/2 a", "!L 6 1/1 p~d~1~WARRIOR~nope~x", "+E", "?Lx", "-L extra" }) do
        A.SendChatMessage(line, "CHANNEL", nil, id)
        api.pump(A)
    end
    T.eq(B.Dungeons.listings.Brakkus, nil, "the -L line removed the card; nothing else broke")
end)

T.test("Dungeons: /lfg off, settings and the addon switch", function()
    local A, B = two()
    list(A, "The Deadmines", "h", "")
    A.__slash("/lfg off")
    T.no(A.Dungeons:MyListing())
    T.has(api.chat_text(A), "your listing is removed")
    api.tick(A, 2)
    T.eq(B.Dungeons.listings.Brakkus, nil)
    -- the tooltip line on players in the world
    list(A, "The Deadmines", "h", "")
    api.mouseover(B, "Brakkus")
    T.has(api.tooltip_text(B), "Group looking for The Deadmines (healer)")
    B.ClassicPlus_Manager:SetSetting("Dungeons", "showInTooltip", false)
    api.mouseover(B, "Brakkus")
    T.lacks(api.tooltip_text(B), "Group looking for")
    -- switching the addon off closes the window and removes the listing
    A.WenillaCore:SetAddonEnabled("Dungeons", false)
    T.hidden(A.Dungeons_Frame)
    T.no(A.Dungeons:MyListing())
    A.__slash("/lfg")
    T.hidden(A.Dungeons_Frame)
    T.has(api.chat_text(A), "Dungeons is switched off")
end)

T.test("Dungeons: Persona profile on hover when Persona is loaded", function()
    local A, B = two()
    list(A, "The Deadmines", "h", "")
    local cache = B.Persona_DB.cache[B.GetRealmName()]
    cache.Brakkus = { name = "Brakkus Ironjaw", title = "Sergeant of the Watch", status = "ic", rev = 1, seen = B.time() }
    board(B)
    api.enter(B.Dungeons_BoardRow1)
    local tip = api.tooltip_text(B)
    T.has(tip, "Persona: Brakkus Ironjaw")
    T.has(tip, "<Sergeant of the Watch>")
    T.has(tip, "In character")
end)

T.test("Dungeons: demo listings follow /wnl demo", function()
    local env = T.suite({ name = "Herald", class = "HUNTER", level = 20 })
    env.__slash("/wnl demo")
    api.tick(env, 2)
    T.ok(env.Dungeons.listings.Brakkus and env.Dungeons.listings.Brakkus.demo, "demo listing")
    env.__slash("/lfg")
    T.shown(env.Dungeons_BoardRow1)
    env.__slash("/wnl demo")
    api.tick(env, 2)
    T.eq(env.Dungeons.listings.Brakkus, nil)
end)
