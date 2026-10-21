--[[
    runner.lua - everything UI Studio asks Lua for, answered as one JSON string (the same from a
    native lua5.1 and from lupa inside Python). Set STUDIO first:
        STUDIO.mode = "shots"      run a shots file (see shoot_one.lua for the other fields)
        STUDIO.mode = "read"       STUDIO.file's globals (STUDIO.globals = { "WenillaCore_Layout" }),
                                   run in an empty sandbox: Layout.lua, SavedVariables files
    Lua 5.1 (the sim's own rules for the addon code it loads).
]]--
local P = STUDIO or {}

local function enc(v, depth, seen)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.10g", v)
    end
    if t == "string" then
        return '"' .. string.gsub(v, '[%c"\\]', function(c)
            if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
            return string.format("\\u%04x", string.byte(c))
        end) .. '"'
    end
    if t ~= "table" or depth > 40 or seen[v] then return "null" end
    seen[v] = true
    local n, count = 0, 0
    for k in pairs(v) do
        count = count + 1
        if type(k) == "number" and k >= 1 and k == math.floor(k) and k > n then n = k end
    end
    local out = {}
    if count > 0 and n == count then
        for i = 1, n do out[i] = enc(v[i], depth + 1, seen) end
        seen[v] = nil
        return "[" .. table.concat(out, ",") .. "]"
    end
    for k, x in pairs(v) do
        if type(k) == "string" or type(k) == "number" then
            local tx = type(x)
            if tx ~= "function" and tx ~= "userdata" and tx ~= "thread" then
                table.insert(out, enc(tostring(k), 0, {}) .. ":" .. enc(x, depth + 1, seen))
            end
        end
    end
    seen[v] = nil
    if count == 0 then return "{}" end
    return "{" .. table.concat(out, ",") .. "}"
end
local function json(v) return enc(v, 0, {}) end

if P.mode == "read" then
    local box = {}
    local chunk, err = loadfile(P.file)
    if not chunk then return json({ error = tostring(err) }) end
    setfenv(chunk, box)
    local ok, e = pcall(chunk)
    if not ok then return json({ error = tostring(e) }) end
    local res = {}
    for _, g in ipairs(P.globals or {}) do res[g] = box[g] end
    return json(res)
end

return json(dofile(P.here .. "/shoot_one.lua"))
