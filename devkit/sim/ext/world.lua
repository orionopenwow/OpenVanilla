--[[
    ext/world.lua - the World channel's server side for the sim (world server patch
    realm/mangos/pending/0007-openvanilla-world-channel.patch, OpenVanilla/World.cpp), so the Chat
    addon's World tab can be tested end to end.

    The fake server keeps one "World" channel on the bus. Joining is done the way the real
    server does it: the client is put in the channel (CHAT_MSG_CHANNEL_NOTICE YOU_JOINED), and
    its lines reach every member through the normal channel routing.

    Test helpers added to api:
        api.world_server(env[, opts])   answers env's ".wnl worldon" / ".wnl worldoff" (joins or
                                        leaves World, remembers it per character like
                                        openvanilla_world_pref, then sends "WO 1" / "WO 0") and,
                                        unless opts.off or the character switched World off,
                                        joins env now (the login join)
        api.world_discord(bus, name, text[, scope])
                                        what ".wnl worldsay <name> <text>" does: "WD W,<name>,<text>"
                                        to every client in World (scope "G": "WD G,..." to all)
        api.world_members(bus)          { env = true } of the clients in World
    State on the bus: __world_off[name] = true for characters that switched World off.
]]--

return function(api, H)
    local WORLD = "World"

    local function busOf(x) return x.__bus or x end

    function api.world_members(x)
        local bus = busOf(x)
        local c = bus.channels and bus.channels[string.lower(WORLD)]
        local out = {}
        if c then for e in pairs(c.members) do out[e] = true end end
        return out
    end

    function api.world_server(env, opts)
        opts = opts or {}
        local bus = env.__bus
        bus.__world_off = bus.__world_off or {}
        if opts.off then bus.__world_off[env.__name] = true end
        api.on_server(env, "worldon", function()
            bus.__world_off[env.__name] = nil
            env.JoinChannelByName(WORLD)
            api.server_packet(env, "WO", "1")
        end)
        api.on_server(env, "worldoff", function()
            bus.__world_off[env.__name] = true
            env.LeaveChannelByName(WORLD)
            api.server_packet(env, "WO", "0")
        end)
        if not bus.__world_off[env.__name] then env.JoinChannelByName(WORLD) end
        api.pump(env)
    end

    function api.world_discord(x, name, text, scope)
        local bus = busOf(x)
        scope = scope or "W"
        local targets = {}
        if scope == "W" then
            for e in pairs(api.world_members(bus)) do table.insert(targets, e) end
        else
            for _, e in ipairs(bus.clients) do table.insert(targets, e) end
        end
        for _, e in ipairs(targets) do api.server_packet(e, "WD", scope .. "," .. name .. "," .. text) end
        return table.getn(targets)
    end
end
