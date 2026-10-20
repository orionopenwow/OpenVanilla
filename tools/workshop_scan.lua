--[[
    workshop_scan.lua - the Lua half of tools/workshop_scan.py. Loads one addon folder into a fresh
    fake 1.12.1 client (devkit/sim), logs in, runs two seconds of OnUpdate, and prints one JSON
    object describing what happened. Not meant to be run by hand; see workshop_scan.py.

        lua5.1 tools/workshop_scan.lua <sim_dir> <repo_root> <addon_dir> [known_saved_csv] [dep_dir ...]

    The sim runs Lua only. XML files are read for <Script file=> / <Include file=> (those Lua files
    run in order) and named frames (created as plain frames so later code can find them); XML
    OnLoad/OnEvent handlers do not run.
]]--

local sim_dir, repo, addon_dir, known_csv = arg[1], arg[2], arg[3], arg[4] or ""
local deps = {}
for i = 5, table.getn(arg) do table.insert(deps, arg[i]) end

local api = dofile(sim_dir .. "/wow_api.lua")
api.repo = repo
api.reset_bus()

local findings = {}
local function finding(kind, severity, detail, where)
    table.insert(findings, { kind = kind, severity = severity, detail = detail, where = where })
end

local env = api.new_client({ name = "Scanner", repo = repo, art = true })

-- getfenv(0) / getfenv(f) must answer the client's sandbox, not the host's _G: addons such as pfUI
-- build their own environment with setmetatable({}, {__index = getfenv(0)}).
do
    local base, real_get = rawget(env, "__base"), getfenv
    base.getfenv = function(f)
        if f == 0 then return env end
        if f == nil then f = 1 end
        local r = real_get(type(f) == "number" and f + 1 or f)
        if r == _G then return env end
        return r
    end
end

-- The real client takes frame types in any case (CreateFrame("FRAME")); the sim wants the
-- canonical spelling.
do
    local base = rawget(env, "__base")
    local real_create = base.CreateFrame
    local CANON = {}
    for _, t in ipairs({ "Frame", "Button", "CheckButton", "EditBox", "StatusBar", "ScrollFrame", "Slider",
        "GameTooltip", "Model", "PlayerModel", "MessageFrame", "ScrollingMessageFrame", "ColorSelect",
        "Minimap", "SimpleHTML", "Cooldown", "LootButton", "DressUpModel", "TabardModel", "MovieFrame",
        "WorldFrame" }) do CANON[string.lower(t)] = t end
    base.CreateFrame = function(ftype, ...)
        if type(ftype) == "string" and CANON[string.lower(ftype)] then ftype = CANON[string.lower(ftype)] end
        return real_create(ftype, ...)
    end
end

-- loadstring: the chunk must see the client's globals (the game has one global table), and Lua
-- 5.0 refuses 5.1-only syntax -- Ace2 feature-tests "function(...) return ... end" exactly so.
do
    local base, real_load = rawget(env, "__base"), loadstring
    base.loadstring = function(src, name)
        if type(src) == "string" then
            for _, it in ipairs(api.guard.scan(src)) do
                if string.find(it.msg, "'...' used", 1, true) or string.find(it.msg, "length operator", 1, true)
                    or string.find(it.msg, "'%' operator", 1, true) then
                    return nil, "[string]:" .. it.line .. ": " .. it.msg
                end
            end
        end
        local chunk, err = real_load(src, name)
        if chunk then setfenv(chunk, env) end
        return chunk, err
    end
end

-- WoW skips a UTF-8 byte-order mark at the start of a Lua file; lua5.1's loadfile does not.
do
    local real_run = api.run_file
    api.run_file = function(e, path, label)
        local f = io.open(path, "rb")
        local head = f and f:read(3)
        if f then f:close() end
        if head ~= "\239\187\191" then return real_run(e, path, label) end
        f = io.open(path, "rb")
        local src = string.sub(f:read("*a"), 4)
        f:close()
        local tmp = os.tmpname()
        local o = io.open(tmp, "wb")
        o:write(src)
        o:close()
        local ok = real_run(e, tmp, label)
        os.remove(tmp)
        return ok
    end
end

-- ------------------------------------------------------------------ XML-aware addon loading

local function read_file(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function dirname(p) return string.match(p, "^(.*)/[^/]*$") or "." end

local xml_frames, xml_files = 0, 0
local FRAME_TYPES = { Frame = 1, Button = 1, CheckButton = 1, EditBox = 1, StatusBar = 1, ScrollFrame = 1,
    Slider = 1, GameTooltip = 1, Model = 1, MessageFrame = 1, ScrollingMessageFrame = 1, PlayerModel = 1 }

local function run_xml(path, label, depth)
    if depth > 8 then return true end
    local src = read_file(path)
    if not src then
        table.insert(env.__errors, "missing file: " .. label)
        return false
    end
    xml_files = xml_files + 1
    src = string.gsub(src, "<!%-%-.-%-%->", "")
    local ok = true
    local base = dirname(path)
    -- Script and Include tags, in document order
    local pos = 1
    while true do
        local s, e, tag, file = string.find(src, "<(%a+)[^>]-file%s*=%s*\"([^\"]+)\"", pos)
        if not s then break end
        pos = e + 1
        local rel = string.gsub(file, "\\", "/")
        if tag == "Script" then
            ok = api.run_file(env, base .. "/" .. rel, label .. " > " .. rel) and ok
        elseif tag == "Include" and string.match(string.lower(rel), "%.lua$") then
            ok = api.run_file(env, base .. "/" .. rel, label .. " > " .. rel) and ok
        elseif tag == "Include" then
            ok = run_xml(base .. "/" .. rel, label .. " > " .. rel, depth + 1) and ok
        end
    end
    -- named frames (top level and nested; $parent names are skipped)
    for ftype, name in string.gmatch(src, "<(%a+)[^>]-%sname%s*=%s*\"([%w_]+)\"") do
        if FRAME_TYPES[ftype] and rawget(env, name) == nil then
            local made = pcall(env.CreateFrame, ftype == "GameTooltip" and "GameTooltip" or ftype, name)
            if made then xml_frames = xml_frames + 1 end
        end
    end
    return ok
end

local function split_list(s)
    local out = {}
    for x in string.gmatch(s or "", "[^,%s]+") do table.insert(out, x) end
    return out
end

local function find_toc(dir, name)
    local direct = dir .. "/" .. name .. ".toc"
    if read_file(direct) then return direct end
    for _, f in ipairs(api.list_dir(dir)) do
        if string.lower(f) == string.lower(name) .. ".toc" then return dir .. "/" .. f end
    end
end

local function load(dir)
    dir = string.gsub(dir, "/+$", "")
    local name = string.match(dir, "([^/]+)$")
    if env.__addons[name] then return true, env.__addons[name] end
    local toc_path = find_toc(dir, name)
    local toc = toc_path and api.read_toc(toc_path)
    if not toc then
        table.insert(env.__errors, "no " .. name .. ".toc in " .. dir)
        return false
    end
    env.__addons[name] = { meta = toc.meta, dir = dir, files = toc.files }
    table.insert(env.__addon_order, name)
    local ok = true
    for _, file in ipairs(toc.files) do
        local rel = string.gsub(file, "\\", "/")
        if string.match(string.lower(rel), "%.xml$") then
            ok = run_xml(dir .. "/" .. rel, name .. "/" .. rel, 0) and ok
        elseif string.match(string.lower(rel), "%.lua$") then
            ok = api.run_file(env, dir .. "/" .. rel, name .. "/" .. rel) and ok
        end
    end
    local svs = split_list(toc.meta.SavedVariables)
    for _, v in ipairs(split_list(toc.meta.SavedVariablesPerCharacter)) do table.insert(svs, v) end
    env.__addons[name].saved = svs
    if name == "WenillaCore" then api.watch_core(env) end
    api.fire(env, "ADDON_LOADED", name)
    return ok, env.__addons[name]
end

-- ------------------------------------------------------------------------------------ run it

local dep_saved = {}
for _, d in ipairs(deps) do
    local _, dinfo = load(d)
    for _, v in ipairs(dinfo and dinfo.saved or {}) do dep_saved[v] = true end
end
local n_dep_errors = table.getn(env.__errors)
local loaded, info = load(addon_dir)
local target = string.match(string.gsub(addon_dir, "/+$", ""), "([^/]+)$")
local meta = info and info.meta or {}
local own_saved = {}
for _, v in ipairs(info and info.saved or {}) do own_saved[v] = true end
for v in pairs(dep_saved) do own_saved[v] = true end   -- a dependency's own reads are fine

local function count(t) return table.getn(t) end
local chat_load, addon_load = count(env.__chat_sent), count(env.__addon_sent)
local errors_load = count(env.__errors)

api.login(env)
local chat_login, addon_login = count(env.__chat_sent), count(env.__addon_sent)
local errors_login = count(env.__errors)
api.tick(env, 2, 0.1)

if chat_login > 0 then
    local first = env.__chat_sent[1]
    finding("chat-at-load", "high", "sends a chat message while loading or at login (" .. tostring(first.kind) .. ": "
        .. string.sub(tostring(first.msg), 1, 80) .. ")", chat_load > 0 and "load" or "login")
end
if addon_login > 0 then
    local first = env.__addon_sent[1]
    finding("addon-message-at-load", "medium", "sends an addon message while loading or at login (prefix "
        .. tostring(first.prefix) .. ", " .. tostring(first.kind) .. ")", addon_load > 0 and "load" or "login")
end
if count(env.__chat_sent) > chat_login then
    finding("chat-on-timer", "medium", "sends chat on its own within two seconds of login", "tick")
end

-- other addons' SavedVariables (names passed in by the Python side) and os/io
local known = {}
for _, v in ipairs(split_list(known_csv)) do known[v] = true end
for k in pairs(env.__unknown_reads) do
    if k == "os" or k == "io" then
        finding("os-io", "high", "reaches for the '" .. k .. "' library (the game has none; a sandbox escape attempt or a port bug)", "runtime")
    elseif known[k] and not own_saved[k] then
        finding("reads-other-saved", "medium", "reads another addon's saved variables: " .. k, "runtime")
    end
end

-- errors, split into the addon's bugs and the sim's gaps
-- Guard hits that are syntax in Lua 5.0 (#, %, '...', [=[ ) break the file; the 5.1 library
-- names (select, string.match/gmatch, :match) only fail on the code path that calls them, and
-- multi-expansion addons often guard those ("string.gmatch or string.gfind"), so they count as
-- "partly" unless something actually broke.
local SYNTAX51 = { "length operator", "'%' operator", "'...' used", "long comment", "long string" }
local errors, sim_gaps, lua51, guard = {}, {}, {}, 0
for i = n_dep_errors + 1, count(env.__errors) do
    local e = tostring(env.__errors[i])
    e = string.gsub(e, "\nstack traceback:.*$", "")
    if string.find(e, "real 1.12", 1, true) or string.find(e, "is not modelled by the sim", 1, true) then
        table.insert(sim_gaps, string.sub(e, 1, 300))
    elseif string.find(e, "not a 1.12 event", 1, true) then
        table.insert(lua51, e)   -- registering a later client's event: harmless in 1.12, never fires
    elseif string.find(e, "lua5.0 guard", 1, true) then
        guard = guard + 1
        local hard = false
        for _, k in ipairs(SYNTAX51) do if string.find(e, k, 1, true) then hard = true end end
        table.insert(hard and errors or lua51, string.sub(e, 1, 300))
    else
        if string.find(e, "^syntax") then guard = guard + 1 end
        table.insert(errors, string.sub(e, 1, 300))
    end
end
if count(lua51) > 0 then
    finding("lua51-calls", "info", count(lua51) .. " Lua 5.1 / later-client call(s) on some code path, e.g. " .. string.gsub(lua51[1], "^lua5.0 guard: ", ""), "static")
end
for _, e in ipairs(env.__pcall_errors) do
    if not string.find(e, "real 1.12", 1, true) then table.insert(errors, "swallowed by pcall: " .. string.sub(e, 1, 280)) end
end

local compat
if not info then compat = "unknown"
elseif count(errors) > 0 then compat = "needs-fixes"
elseif count(sim_gaps) > 0 or count(lua51) > 0 then compat = "partly"
else compat = "works" end

local saved = {}
for _, v in ipairs(info and info.saved or {}) do table.insert(saved, v) end
local unknown = {}
for k in pairs(env.__unknown_reads) do table.insert(unknown, k) end
table.sort(unknown)

-- --------------------------------------------------------------------------------- tiny JSON

local function q(s)
    s = string.gsub(tostring(s), '[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n" end
        return string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. s .. '"'
end
local function enc(v)
    local t = type(v)
    if t == "table" then
        if v[1] ~= nil or next(v) == nil then
            local parts = {}
            for _, x in ipairs(v) do table.insert(parts, enc(x)) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do table.insert(keys, k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do table.insert(parts, q(k) .. ":" .. enc(v[k])) end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif t == "boolean" or t == "number" then return tostring(v)
    elseif v == nil then return "null" end
    return q(v)
end

local cut = {}
for i = 1, math.min(count(errors), 25) do cut[i] = errors[i] end
local gaps = {}
for i = 1, math.min(count(sim_gaps), 10) do gaps[i] = sim_gaps[i] end

io.write(enc({
    addon = target,
    loaded = info ~= nil,
    title = meta.Title or target,
    interface = meta.Interface or "",
    saved = saved,
    compat = compat,
    errors = cut,
    error_count = count(errors),
    guard_issues = guard,
    sim_gaps = gaps,
    findings = findings,
    xml = { files = xml_files, frames_stubbed = xml_frames },
    errors_at = { load = errors_load - n_dep_errors, login = errors_login - errors_load },
    unknown_globals = unknown,
}))
io.write("\n")
