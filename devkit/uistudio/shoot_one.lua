--[[
    shoot_one.lua - UI Studio's shot runner: like devkit/sim/render/shoot.lua, but for one shot (or
    all of a file), without os.exit (it also runs inside Python through lupa), and with the
    shots file's errors returned instead of printed.

        STUDIO = { sim = "<repo>/devkit/sim", repo = "<repo>", shots = "<file>", out = "<dir>", only = "<shot>" or nil }
        dofile("shoot_one.lua")  -> returns { {name=, objects=, error=, tunables=}, ... }
]]--
local P = STUDIO or {}
local sim, repo, shots, out, only = P.sim, P.repo, P.shots, P.out, P.only
local api = dofile(sim .. "/wow_api.lua")
api.repo = repo
local T = dofile(sim .. "/testkit.lua")(api)
local dump = dofile(sim .. "/render/dump.lua")(api)

local S = { list = {} }
function S.shot(name, fn) table.insert(S.list, { name = name, fn = fn }) end
S.T = T
local chunk, err = loadfile(shots)
if not chunk then return { { name = "?", error = err } } end
chunk(S, api)

local results = {}
for _, s in ipairs(S.list) do
    if not only or only == s.name then
        api.reset_bus()
        local ok, env, frame, extra = pcall(s.fn)
        local r = { name = s.name }
        if not ok then
            r.error = tostring(env)
        else
            -- the studio's Layout.lua on everything that exists now (the game does this twice a second)
            local W = env and rawget(env, "WenillaCore")
            if W and W.LayoutApplyAll then pcall(W.LayoutApplyAll) end
            local errs = api.errors(env)
            if errs and table.getn(errs) > 0 then r.error = "Lua error: " .. tostring(errs[1]) end
            r.objects = dump(env, frame, out .. "/" .. s.name .. ".json", extra)
            if W and type(W.tunables) == "table" then
                r.tunables = {}
                for k, v in pairs(W.tunables) do r.tunables[k] = v end
            end
        end
        table.insert(results, r)
    end
end
return results
