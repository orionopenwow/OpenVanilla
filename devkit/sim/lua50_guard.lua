--[[
    lua50_guard.lua - best-effort static check for Lua 5.1-only syntax in addon files.

    The 1.12.1 client runs Lua 5.0. lua5.1 happily accepts all of the following, the real
    client does not, so the sim scans every file before running it:
        #t                  length operator              (5.0: table.getn / string.len)
        a % b               modulo operator              (5.0: math.mod)
        select(...)         no such function in 1.12
        string.gmatch/match/reverse, table.maxn, :gmatch( / :match(   (5.1 library names)
        ...                 as an expression             (5.0: the implicit 'arg' table;
                                                          '...' is legal only in a parameter list)
        [==[ ]==]           long brackets with '='       (5.0 reads "--[==[" as a line comment)
    Comments and string literals are skipped. Usage:
        local guard = dofile("lua50_guard.lua")
        local issues = guard.scan(source_text)     -- { {line=, msg=}, ... }
        local issues = guard.scan_file(path)       -- same, plus .file
]]--

local G = {}

local LIB51 = {
    string = { gmatch = "string.gmatch is Lua 5.1 (use string.gfind)",
               match = "string.match is Lua 5.1 (use string.find with captures)",
               reverse = "string.reverse is Lua 5.1" },
    table = { maxn = "table.maxn is Lua 5.1", wipe = "table.wipe is not 1.12" },
}
local METHOD51 = { gmatch = true, match = true }

-- Long bracket at position i ("[", "[=[", ...). Returns level (count of '=') or nil.
local function longOpen(src, i)
    local eq = string.match(src, "^%[(=*)%[", i)
    if eq then return string.len(eq) end
end

-- Skips a long bracket body opened at i with the given level; returns index after it and
-- the number of newlines consumed. Level 0 nests like Lua 5.0's [[ ]].
local function skipLong(src, i, level)
    local open = 2 + level
    local j = i + open
    local close = "]" .. string.rep("=", level) .. "]"
    local depth = 1
    local n = string.len(src)
    while j <= n do
        if level == 0 and string.sub(src, j, j + 1) == "[[" then
            depth = depth + 1; j = j + 2
        elseif string.sub(src, j, j + string.len(close) - 1) == close then
            depth = depth - 1; j = j + string.len(close)
            if depth == 0 or level > 0 then break end
        else
            j = j + 1
        end
    end
    local body = string.sub(src, i, j - 1)
    local _, nl = string.gsub(body, "\n", "")
    return j, nl
end

function G.scan(src)
    local issues = {}
    local function add(line, msg) table.insert(issues, { line = line, msg = msg }) end
    local i, n, line = 1, string.len(src), 1
    local toks = {}            -- recent significant tokens
    local afterFunction = false
    local inParams = false

    local function prevTok(k) return toks[table.getn(toks) - (k or 0)] end
    local function push(t) table.insert(toks, t); if table.getn(toks) > 8 then table.remove(toks, 1) end end

    -- skip a "#!" first line
    if string.sub(src, 1, 1) == "#" then
        local e = string.find(src, "\n", 1, true) or n
        i = e
    end

    while i <= n do
        local c = string.sub(src, i, i)
        if c == "\n" then
            line = line + 1; i = i + 1
        elseif string.find(c, "%s") then
            i = i + 1
        elseif string.sub(src, i, i + 1) == "--" then
            local lv = longOpen(src, i + 2)
            if lv then
                if lv > 0 then add(line, "long comment '--[" .. string.rep("=", lv) .. "[' is Lua 5.1 (5.0 reads it as a one-line comment)") end
                local j, nl = skipLong(src, i + 2, lv)
                line = line + nl; i = j
            else
                local e = string.find(src, "\n", i, true)
                i = e or (n + 1)
            end
        elseif c == "\"" or c == "'" then
            local j = i + 1
            while j <= n do
                local d = string.sub(src, j, j)
                if d == "\\" then
                    if string.sub(src, j + 1, j + 1) == "\n" then line = line + 1 end
                    j = j + 2
                elseif d == c then break
                elseif d == "\n" then line = line + 1; j = j + 1   -- malformed; keep counting
                else j = j + 1 end
            end
            i = j + 1
            push("<str>")
        elseif c == "[" and longOpen(src, i) then
            local lv = longOpen(src, i)
            if lv > 0 then add(line, "long string '[" .. string.rep("=", lv) .. "[' is Lua 5.1") end
            local j, nl = skipLong(src, i, lv)
            line = line + nl; i = j
            push("<str>")
        elseif string.find(c, "[%a_]") then
            local word = string.match(src, "^[%w_]+", i)
            i = i + string.len(word)
            local p1, p2 = prevTok(0), prevTok(1)
            if word == "select" and p1 ~= "." and p1 ~= ":" and string.match(src, "^%s*%(", i) then
                add(line, "select() does not exist in 1.12 (Lua 5.0: use the 'arg' table)")
            end
            if p1 == "." and LIB51[p2] and LIB51[p2][word] then add(line, LIB51[p2][word]) end
            if p1 == ":" and METHOD51[word] and string.match(src, "^%s*%(", i) then
                add(line, "':" .. word .. "(' looks like the Lua 5.1 string method (5.0 strings have no methods)")
            end
            if word == "function" then afterFunction = true end
            push(word)
        elseif string.find(c, "%d") or (c == "." and string.find(string.sub(src, i + 1, i + 1), "%d")) then
            local num = string.match(src, "^0[xX]%x+", i) or string.match(src, "^%d*%.?%d*[eE][%+%-]?%d+", i)
                or string.match(src, "^%d*%.?%d*", i)
            i = i + math.max(1, string.len(num))
            push("<num>")
        else
            local three, two = string.sub(src, i, i + 2), string.sub(src, i, i + 1)
            local tok
            if three == "..." then tok = "..."
            elseif two == ".." or two == "==" or two == "~=" or two == "<=" or two == ">=" then tok = two
            else tok = c end
            i = i + string.len(tok)
            if tok == "#" then
                add(line, "length operator '#' is Lua 5.1 (use table.getn / string.len)")
            elseif tok == "%" then
                add(line, "'%' operator is Lua 5.1 (use math.mod)")
            elseif tok == "..." and not inParams then
                add(line, "'...' used as an expression is Lua 5.1 (5.0 functions read the implicit 'arg' table)")
            elseif tok == "(" and afterFunction then
                inParams = true; afterFunction = false
            elseif tok == ")" and inParams then
                inParams = false
            elseif afterFunction and tok ~= "." and tok ~= ":" then
                afterFunction = false
            end
            push(tok)
        end
    end
    return issues
end

function G.scan_file(path)
    local f = io.open(path, "rb")
    if not f then return { { file = path, line = 0, msg = "cannot open file" } } end
    local src = f:read("*a")
    f:close()
    local issues = G.scan(src)
    for _, it in ipairs(issues) do it.file = path end
    return issues
end

return G
