--[[
    ext/guildhub.lua - more of the 1.12 client for the sim: officer permissions and notes, the
    guild MOTD, officer chat and the trade window (Guild Hub).

    Runs after ext/social.lua's guild roster (as a late extension) and reuses it: notes written
    with GuildRosterSetPublicNote / GuildRosterSetOfficerNote land on the guild.roster entries.
    Officer = rank index 0 or 1, as in ext/social.lua.

    State on env: __motd_set (GuildSetMOTD lines), __trade (the open trade).

    Test helpers added to api:
        api.trade(A, B, { a_money, b_money, a_items = { {name, count} }, b_items, complete = true })
            A opens a trade with B, both put in money/items, both accept; complete = false
            cancels it instead. Fires TRADE_SHOW, TRADE_MONEY_CHANGED, TRADE_*_ITEM_CHANGED,
            TRADE_ACCEPT_UPDATE, then UI_INFO_MESSAGE "Trade complete." and TRADE_CLOSED.
        api.raid_roster(env, { "Name" | { name, class, level, online }, ... })
            puts raid1..raidN units on env (NPC members, no clients behind them)
]]--

return function(api, H)
    local function shallow(t) local o = {} for k, v in pairs(t or {}) do o[k] = v end return o end
    local TRADE_DONE = "Trade complete."

    local function officer(env) return env.__guild and (env.__guild.rankIndex or 1) <= 1 end

    -- officer chat: CHAT_MSG_OFFICER to the guild's officers (the stock router only knows guild chat)
    local route = api.__route_chat
    function api.__route_chat(env, msg, kind, target)
        if kind == "OFFICER" then
            if not (env.__guild and officer(env)) then return end
            msg = env.__bus:serverText(msg)
            for _, e in ipairs(env.__bus.clients) do
                if e.__guild and e.__guild.name == env.__guild.name and officer(e) then
                    env.__bus:deliver(e, "CHAT_MSG_OFFICER", msg, env.__name, "")
                end
            end
            return
        end
        return route(env, msg, kind, target)
    end

    -- the roster entry behind GetGuildRosterInfo(i), created in guild.roster when it was a bus client
    local function entry(env, i)
        local g = env.__guild
        if not g then return nil end
        local name = env.GetGuildRosterInfo(i)
        if not name then return nil end
        if name == env.__name then return g, true end
        g.roster = g.roster or {}
        for _, m in ipairs(g.roster) do if (m.name or m[1]) == name then return m end end
        local o = env.__bus.by_name[name]
        local m = { name = name, rank = o and o.__guild and o.__guild.rank or "Member", rankIndex = o and o.__guild and o.__guild.rankIndex or 3 }
        table.insert(g.roster, m)
        return m
    end

    api.client_late_extensions = api.client_late_extensions or {}
    table.insert(api.client_late_extensions, function(env, B)
        local bus = env.__bus
        local function yes() return officer(env) and 1 or nil end
        B.CanEditOfficerNote, B.CanViewOfficerNote, B.CanEditMOTD, B.CanGuildRemove = yes, yes, yes, yes
        rawset(env, "__motd_set", {})
        B.GuildRosterSetPublicNote = function(i, text)
            local m = entry(env, i)
            if m then m.note = text end
            bus:later(function() api.fire(env, "GUILD_ROSTER_UPDATE") end)
        end
        B.GuildRosterSetOfficerNote = function(i, text)
            local m = entry(env, i)
            if m then m.officernote = text end
            bus:later(function() api.fire(env, "GUILD_ROSTER_UPDATE") end)
        end
        B.GuildSetMOTD = function(text)
            table.insert(env.__motd_set, text)
            local g = env.__guild
            if not g then return end
            for _, e in ipairs(bus.clients) do
                if e.__guild and e.__guild.name == g.name then
                    e.__guild.motd = text
                    bus:deliver(e, "GUILD_MOTD", text)
                end
            end
        end

        -- the trade window
        B.GetPlayerTradeMoney = function() local t = rawget(env, "__trade") return t and t.give or 0 end
        B.GetTargetTradeMoney = function() local t = rawget(env, "__trade") return t and t.get or 0 end
        local function itemInfo(list, i)
            local it = list and list[i]
            if it then return it[1] or it.name, "Interface\\Icons\\INV_Misc_QuestionMark", it[2] or it.count or 1, 1, 1, nil end
        end
        B.GetTradePlayerItemInfo = function(i) local t = rawget(env, "__trade") return itemInfo(t and t.giveItems, i) end
        B.GetTradeTargetItemInfo = function(i) local t = rawget(env, "__trade") return itemInfo(t and t.getItems, i) end
    end)

    function api.trade(A, B, opts)
        opts = opts or {}
        local sides = {
            { env = A, other = B, give = opts.a_money or 0, get = opts.b_money or 0, giveItems = opts.a_items, getItems = opts.b_items },
            { env = B, other = A, give = opts.b_money or 0, get = opts.a_money or 0, giveItems = opts.b_items, getItems = opts.a_items },
        }
        for _, s in ipairs(sides) do
            local e = s.env
            rawset(e, "__trade", { give = 0, get = 0 })
            e.__units.npc = shallow(s.other.__units.player)
            api.fire(e, "TRADE_SHOW")
        end
        for _, s in ipairs(sides) do
            local t = rawget(s.env, "__trade")
            t.give, t.get, t.giveItems, t.getItems = s.give, s.get, s.giveItems, s.getItems
            api.fire(s.env, "TRADE_MONEY_CHANGED")
            api.fire(s.env, "TRADE_PLAYER_ITEM_CHANGED", 1)
            api.fire(s.env, "TRADE_TARGET_ITEM_CHANGED", 1)
            api.fire(s.env, "TRADE_ACCEPT_UPDATE", 1, 1)
        end
        for _, s in ipairs(sides) do
            local e = s.env
            if opts.complete ~= false then
                e.__money = e.__money - s.give + s.get
                api.fire(e, "UI_INFO_MESSAGE", TRADE_DONE)
            end
            api.fire(e, "TRADE_CLOSED")
            rawset(e, "__trade", nil)
            e.__units.npc = nil
        end
        api.pump(A)
    end

    function api.raid_roster(env, list)
        for i = 1, 40 do env.__units["raid" .. i] = nil end
        for i, m in ipairs(list) do
            local d = type(m) == "string" and { name = m } or m
            env.__units["raid" .. i] = { name = d.name or d[1], class = d.class or "WARRIOR", level = d.level or 60,
                isPlayer = true, health = 100, healthMax = 100, online = d.online ~= false }
        end
        api.fire(env, "RAID_ROSTER_UPDATE")
    end
end
