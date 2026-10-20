--[[
    ext/social.lua - more of the 1.12 client for the sim: the friends list, /who, the guild
    roster and guild invites, group invites, the loot method, world map zones and the stock
    Friends frame (Social, Dungeons).

    Client options (api.new_client):
        friends = { "Name" | { name | [1], level, class, zone | area, connected }, ... }
            a friend who is a client on the bus is online with that client's level, class and
            zone; anyone else is online only when connected = true
        guild.roster = { { name | [1], rank, rankIndex, level, class, zone, note, officernote,
            online, lastOnline = { years, months, days, hours } }, ... }, guild.motd, guild.ranks
            the roster also holds the player and every bus client in the same guild
    State on env: __friends, __invites (InviteByName), __who_sent, __guild_invites,
        __loot_method ("group" or { "master", 0 }; nil is free for all), __map_zoom ({ c, z }).

    Test helpers added to api:
        api.add_world_player(env, { name, level, class, race, zone, guild })   someone /who finds
        api.who_search(bus, query)       the /who matcher
        api.announce_online(env[, off])  friends and guild mates hear that env came online
                                         (api.login does this for every client)
        api.log_off(env)                 env leaves the realm; friends see it go offline
        api.set_level(env, level)        ding: PLAYER_LEVEL_UP
]]--

return function(api, H)
    local NOOP = H.NOOP
    local ST = api.ST

    local function shallow(t) local o = {} for k, v in pairs(t or {}) do o[k] = v end return o end
    local function className(c) return api.CLASS_NAMES[string.upper(c or "")] or c end

    -- 1.12 world map zones per continent, in GetMapZones order.
    api.MAP_ZONES = {
        { "Ashenvale", "Azshara", "Darkshore", "Darnassus", "Desolace", "Durotar", "Dustwallow Marsh", "Felwood",
          "Feralas", "Moonglade", "Mulgore", "Orgrimmar", "Silithus", "Stonetalon Mountains", "Tanaris", "Teldrassil",
          "The Barrens", "Thousand Needles", "Thunder Bluff", "Un'Goro Crater", "Winterspring" },
        { "Alterac Mountains", "Arathi Highlands", "Badlands", "Blasted Lands", "Burning Steppes", "Deadwind Pass",
          "Dun Morogh", "Duskwood", "Eastern Plaguelands", "Elwynn Forest", "Hillsbrad Foothills", "Ironforge",
          "Loch Modan", "Redridge Mountains", "Searing Gorge", "Silverpine Forest", "Stormwind City",
          "Stranglethorn Vale", "Swamp of Sorrows", "The Hinterlands", "Tirisfal Glades", "Undercity",
          "Western Plaguelands", "Westfall", "Wetlands" },
    }

    function api.add_world_player(x, def)
        local bus = api.bus_of(x)
        bus.world = bus.world or {}
        table.insert(bus.world, def)
    end

    -- A /who query ('n-"Name" g-"Guild" c-"Class" r-"Race" z-"Zone" 10-20 free words') over the
    -- bus clients and api.add_world_player entries.
    function api.who_search(bus, q)
        local pool = {}
        for _, e in ipairs(bus.clients) do
            local u = e.__units.player
            table.insert(pool, { name = u.name, level = u.level, class = className(u.class), race = u.race,
                zone = e.__map.zone or "", guild = e.__guild and e.__guild.name or "" })
        end
        for _, w in ipairs(bus.world or {}) do
            table.insert(pool, { name = w.name, level = w.level or 1, class = className(w.class or "WARRIOR"),
                race = w.race or "Human", zone = w.zone or "", guild = w.guild or "" })
        end
        q = tostring(q or "")
        local want, words = {}, {}
        q = string.gsub(q, '([ngcrz])%-"([^"]*)"', function(k, v) want[k] = string.lower(v) return " " end)
        q = string.gsub(q, "(%d+)%-(%d+)", function(a, b) want.lo, want.hi = tonumber(a), tonumber(b) return " " end)
        for w in string.gmatch(q, "%S+") do
            if tonumber(w) then want.lo, want.hi = tonumber(w), tonumber(w) else table.insert(words, string.lower(w)) end
        end
        local function has(s, sub) return string.find(string.lower(s or ""), sub, 1, true) ~= nil end
        local out = {}
        for _, p in ipairs(pool) do
            local ok = (not want.n or has(p.name, want.n)) and (not want.g or has(p.guild, want.g))
                and (not want.c or string.lower(p.class) == want.c) and (not want.r or has(p.race, want.r))
                and (not want.z or has(p.zone, want.z)) and (not want.lo or (p.level >= want.lo and p.level <= want.hi))
            for _, w in ipairs(words) do
                if ok and not (has(p.name, w) or has(p.zone, w) or has(p.guild, w) or has(p.class, w) or has(p.race, w)) then ok = false end
            end
            if ok then table.insert(out, p) end
        end
        table.sort(out, function(a, b) return a.name < b.name end)
        return out
    end

    function api.announce_online(env, offline)
        local bus = env.__bus
        local n = env.__name
        local text = offline and (n .. " has gone offline.") or ("|Hplayer:" .. n .. "|h[" .. n .. "]|h has come online.")
        for _, e in ipairs(bus.clients) do
            if e ~= env then
                local friend = false
                for _, f in ipairs(e.__friends or {}) do if (f.name or f[1]) == n then friend = true end end
                local mate = e.__guild and env.__guild and e.__guild.name == env.__guild.name
                if friend or mate then
                    bus:deliver(e, "CHAT_MSG_SYSTEM", text)
                    if friend then bus:deliver(e, "FRIENDLIST_UPDATE") end
                    if mate then bus:deliver(e, "GUILD_ROSTER_UPDATE") end
                end
            end
        end
    end

    local login = api.login
    function api.login(env)
        login(env)
        api.announce_online(env)
        api.pump(env)
    end

    function api.log_off(env)
        api.announce_online(env, true)
        api.remove_client(env)
        api.pump(env.__bus)
    end

    function api.set_level(env, level)
        env.__units.player.level = level
        api.fire(env, "PLAYER_LEVEL_UP", level)
    end

    local RANKS = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }

    table.insert(api.client_extensions, function(env, B, opts)
        local bus = env.__bus
        local name = env.__name
        rawset(env, "__friends", {})
        for _, f in ipairs(opts.friends or {}) do
            table.insert(env.__friends, type(f) == "string" and { name = f } or shallow(f))
        end
        for _, k in ipairs({ "__invites", "__who", "__who_sent", "__guild_invites" }) do rawset(env, k, {}) end
        local function later(ev, ...)
            local a = { ... }
            bus:later(function() api.fire(env, ev, unpack(a)) end)
        end

        -- friends
        B.GetNumFriends = function() return #env.__friends end
        B.GetFriendInfo = function(i)
            local f = env.__friends[i]
            if not f then return nil end
            local fname = f.name or f[1]
            local o = bus.by_name[fname or ""]
            if o then
                local u = o.__units.player
                return fname, u.level, className(u.class), o.__map.zone or "", 1, ""
            end
            return fname, f.level or 0, f.class and className(f.class) or "Unknown", f.zone or f.area or "",
                f.connected and 1 or nil, ""
        end
        B.ShowFriends = function() later("FRIENDLIST_UPDATE") end
        B.AddFriend = function(n)
            for _, f in ipairs(env.__friends) do if (f.name or f[1]) == n then return end end
            table.insert(env.__friends, { name = n })
            B.ShowFriends()
        end
        B.RemoveFriend = function(x)
            for i = #env.__friends, 1, -1 do
                if i == x or (env.__friends[i].name or env.__friends[i][1]) == x then table.remove(env.__friends, i) end
            end
            B.ShowFriends()
        end
        B.DelIgnore = function(n)
            for i = #env.__ignores, 1, -1 do if env.__ignores[i] == n then table.remove(env.__ignores, i) end end
            later("IGNORELIST_UPDATE")
        end

        -- group invites and the loot method
        B.InviteByName = function(n)
            table.insert(env.__invites, n)
            local o = bus.by_name[n or ""]
            if o then bus:deliver(o, "PARTY_INVITE_REQUEST", name)
            else bus:deliver(env, "CHAT_MSG_SYSTEM", "Cannot find player '" .. tostring(n) .. "'.") end
        end
        B.GetLootMethod = function()
            local m = env.__loot_method
            if type(m) == "table" then return m[1], m[2], m[3] end
            return m or "freeforall", 0, nil
        end
        B.SetLootMethod = function(m, who)
            env.__loot_method = (m == "master") and { m, 0 } or m
            later("PARTY_LOOT_METHOD_CHANGED")
        end
        B.ConfirmReadyCheck = NOOP

        -- /who answers on the next pump: WHO_LIST_UPDATE after SetWhoToUI(1), else chat lines
        local whoToUI = 0
        B.SetWhoToUI = function(v) whoToUI = tonumber(v) or 0 end
        B.SendWho = function(q)
            table.insert(env.__who_sent, q)
            local toUI = whoToUI
            bus:later(function()
                env.__who = api.who_search(bus, q)
                if toUI == 1 then api.fire(env, "WHO_LIST_UPDATE") return end
                for _, w in ipairs(env.__who) do
                    api.fire(env, "CHAT_MSG_SYSTEM", w.name .. ": Level " .. w.level .. " " .. w.race .. " " .. w.class .. " - " .. w.zone)
                end
                api.fire(env, "CHAT_MSG_SYSTEM", #env.__who .. " player(s) total")
            end)
        end
        B.GetNumWhoResults = function() return #env.__who, #env.__who end
        B.GetWhoInfo = function(i)
            local w = env.__who[i]
            if w then return w.name, w.guild or "", w.level, w.race, w.class, w.zone end
        end
        B.SortWho = NOOP

        -- the guild roster: the player, guild.roster and every bus client in the same guild
        local function roster()
            local g = env.__guild
            if not g then return {} end
            g.roster = g.roster or {}
            local out, seen = {}, {}
            local me = env.__units.player
            table.insert(out, { name = me.name, rank = g.rank or "Officer", rankIndex = g.rankIndex or 1, level = me.level,
                class = me.class, zone = env.__map.zone, note = g.note or "", online = true })
            seen[me.name] = true
            for _, m in ipairs(g.roster) do
                local mname = m.name or m[1]
                if mname and not seen[mname] then
                    seen[mname] = true
                    local e = shallow(m)
                    e.name = mname
                    local o = bus.by_name[mname]
                    if o and o.__guild and o.__guild.name == g.name then
                        e.online, e.level, e.class, e.zone = true, o.__units.player.level, o.__units.player.class, o.__map.zone
                    end
                    table.insert(out, e)
                end
            end
            for _, o in ipairs(bus.clients) do
                local n = o.__units.player.name
                if not seen[n] and o.__guild and o.__guild.name == g.name then
                    seen[n] = true
                    table.insert(out, { name = n, rank = o.__guild.rank or "Member", rankIndex = o.__guild.rankIndex or 3,
                        level = o.__units.player.level, class = o.__units.player.class, zone = o.__map.zone, online = true })
                end
            end
            return out
        end
        local stockCount = B.GetNumGuildMembers
        B.GetNumGuildMembers = function(all)
            local g = env.__guild
            if not (g and g.roster) then return stockCount(all) end
            local list, on = roster(), 0
            for _, m in ipairs(list) do if m.online then on = on + 1 end end
            return #list, on
        end
        B.GuildRoster = function() if env.__guild then later("GUILD_ROSTER_UPDATE") end end
        B.GetGuildRosterInfo = function(i)
            local m = roster()[i]
            if m then
                return m.name, m.rank or "Member", m.rankIndex or 3, m.level or 60, className(m.class or "WARRIOR"),
                    m.zone or "", m.note or "", m.officernote or "", m.online and 1 or nil, m.status or ""
            end
        end
        B.GetGuildRosterLastOnline = function(i)
            local m = roster()[i]
            if m and not m.online and m.lastOnline then return unpack(m.lastOnline) end
        end
        B.GetGuildRosterMOTD = function() return env.__guild and env.__guild.motd or "" end
        local showOffline = 1
        B.GetGuildRosterShowOffline = function() return showOffline end
        B.SetGuildRosterShowOffline = function(v) showOffline = v and v ~= 0 and 1 or nil end
        local function ranks() return (env.__guild and env.__guild.ranks) or RANKS end
        B.GuildControlGetNumRanks = function() return #ranks() end
        B.GuildControlGetRankName = function(i) return ranks()[i] end
        local function officer() return env.__guild and (env.__guild.rankIndex or 1) <= 1 and 1 or nil end
        B.CanGuildInvite, B.CanGuildPromote, B.CanGuildDemote, B.CanEditPublicNote = officer, officer, officer, officer
        -- an invite to a bus client is accepted at once: they join at the lowest rank
        B.GuildInviteByName = function(n)
            table.insert(env.__guild_invites, n)
            local g, o = env.__guild, bus.by_name[n or ""]
            if not (g and o) then return end
            local r = ranks()
            o.__guild = { name = g.name, rank = r[#r], rankIndex = #r - 1, ranks = g.ranks, roster = g.roster, motd = g.motd }
            o.__units.player.guild = g.name
            g.roster = g.roster or {}
            table.insert(g.roster, { name = n, rank = r[#r], rankIndex = #r - 1 })
            later("GUILD_ROSTER_UPDATE")
        end
        local function moveRank(n, d)
            local g = env.__guild
            if not g then return end
            local r = ranks()
            for _, m in ipairs(g.roster or {}) do
                if (m.name or m[1]) == n then
                    m.rankIndex = math.max(1, math.min(#r - 1, (m.rankIndex or 3) + d))
                    m.rank = r[m.rankIndex + 1]
                    local o = bus.by_name[n]
                    if o and o.__guild then o.__guild.rankIndex, o.__guild.rank = m.rankIndex, m.rank end
                end
            end
            later("GUILD_ROSTER_UPDATE")
        end
        B.GuildPromoteByName = function(n) moveRank(n, -1) end
        B.GuildDemoteByName = function(n) moveRank(n, 1) end
        B.GuildRosterSetPublicNote = NOOP

        -- world map zones
        B.GetMapContinents = function() return "Kalimdor", "Eastern Kingdoms" end
        B.GetMapZones = function(c) return unpack(api.MAP_ZONES[c] or {}) end
        B.SetMapZoom = function(c, z) env.__map_zoom = { c, z } end
    end)

    -- the stock Friends frame and ToggleFriendsFrame (FriendsFrame.lua)
    api.client_late_extensions = api.client_late_extensions or {}
    table.insert(api.client_late_extensions, function(env, B)
        local ff = rawget(env, "FriendsFrame")
        if not ff then
            ff = H.newObject(env, "Frame", "FriendsFrame", env.UIParent)
            ST[ff].shown = false
        end
        B.FriendsFrame = ff
        B.ToggleFriendsFrame = function(tab)
            if tab then ff.selectedTab = tab end
            if ff:IsShown() then ff:Hide() else ff:Show() end
        end
    end)
end
