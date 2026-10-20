--[[
    shoot.lua - runs a shots file and writes one JSON per shot for render.py.

        lua5.1 devkit/sim/render/shoot.lua <repo> <shots.lua> <out dir>
        python3 devkit/sim/render/render.py <repo> <out dir>      -> <out dir>/<shot>.png

    A shots file is like a test file: it gets (S, api) and calls S.shot(name, function() ... return
    env, frame [, extra objects] end). Art comes from the repo's Data/Interface (the game's own
    textures must be extracted there, as for the sim's art checks; they are never committed).
]]--
local script = arg and arg[0] or "shoot.lua"
local HERE = string.match(script, "^(.*)[/\\]") or "."
local repo, shots, out = arg[1], arg[2], arg[3]
assert(repo and shots and out, "usage: shoot.lua <repo> <shots.lua> <out dir>")

local api = dofile(HERE .. "/../wow_api.lua")
api.repo = repo
local T = dofile(HERE .. "/../testkit.lua")(api)
local dump = dofile(HERE .. "/dump.lua")(api)
os.execute('mkdir -p "' .. out .. '"')

local S = { list = {} }
function S.shot(name, fn) table.insert(S.list, { name = name, fn = fn }) end
S.T = T
assert(loadfile(shots))(S, api)

local bad = 0
for _, s in ipairs(S.list) do
    api.reset_bus()
    local ok, env, frame, extra = pcall(s.fn)
    if not ok then
        print("FAIL " .. s.name .. ": " .. tostring(env)); bad = bad + 1
    else
        local errs = api.errors(env)
        if errs and table.getn(errs) > 0 then
            print("FAIL " .. s.name .. ": Lua error: " .. tostring(errs[1]))
            bad = bad + 1
        end
        local n = dump(env, frame, out .. "/" .. s.name .. ".json", extra)
        print(string.format("shot %-28s %d objects", s.name, n))
    end
end
os.exit(bad > 0 and 1 or 0)
