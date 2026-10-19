--[[
    run_tests.lua - runs every test in devkit/sim/tests/ against the addons in a repo.

        lua5.1 devkit/sim/run_tests.lua [repo_root] [filter]

    repo_root defaults to two levels above this script (the folder that holds devkit/).
    filter (plain, case-insensitive) keeps the tests whose name or file contains it.
    Prints one line per test (PASS / FAIL / XFAIL), a summary, and exits 1 on any failure.
    Set SIM_VERBOSE=1 to also list each test's unmodelled API use.
]]--

local script = arg and arg[0] or "run_tests.lua"
local HERE = string.match(script, "^(.*)[/\\]") or "."

local function isDir(p)
    local f = io.open(p .. "/Data/Interface/AddOns", "r")
    if f then f:close() return true end
    local ok = os.execute('test -d "' .. p .. '/Data/Interface/AddOns"')
    return ok == 0 or ok == true
end

-- Absolute and lexically normalised ("a/b/../c" -> "a/c"), so a symlinked devkit/ still finds
-- the repo it sits in.
local function absolute(p)
    if string.sub(p, 1, 1) ~= "/" then
        local pwd = os.getenv("PWD") or io.popen("pwd"):read("*l")
        p = pwd .. "/" .. p
    end
    local parts = {}
    for seg in string.gmatch(p, "[^/]+") do
        if seg == ".." then table.remove(parts)
        elseif seg ~= "." then table.insert(parts, seg) end
    end
    return "/" .. table.concat(parts, "/")
end

local repo, filter = arg[1], arg[2]
if repo and not isDir(repo) and not filter then repo, filter = nil, repo end   -- a lone filter
repo = absolute(repo or (HERE .. "/../.."))
if not isDir(repo) then
    io.stderr:write("run_tests: no Data/Interface/AddOns under " .. repo .. "\n")
    os.exit(2)
end

local api = dofile(HERE .. "/wow_api.lua")
api.repo = repo
local T = dofile(HERE .. "/testkit.lua")(api)

-- collect test files
local files = {}
for _, f in ipairs(api.list_dir(HERE .. "/tests")) do
    if string.match(f, "%.lua$") then table.insert(files, f) end
end
table.sort(files)
for _, f in ipairs(files) do
    T.current_file = f
    local chunk, err = loadfile(HERE .. "/tests/" .. f)
    if not chunk then
        T.broken(f, err)
    else
        local ok, lerr = pcall(chunk, T, api)
        if not ok then T.broken(f, lerr) end
    end
end

local started = os.clock()
local res = T.run(filter and string.lower(filter) or nil, os.getenv("SIM_VERBOSE") == "1")
print(string.format("\n%d passed, %d failed, %d known bugs (xfail), %d skipped by filter  [%.2fs, repo %s]",
    res.pass, res.fail, res.xfail, res.skipped, os.clock() - started, repo))
os.exit(res.fail > 0 and 1 or 0)
