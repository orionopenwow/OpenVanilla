--[[
    testkit.lua - the 'T' object every test file receives:  local T, api = ...

        T.test("Threat: VG fills the bars", function()
            local env = T.addon("Threat")               -- client + Threat and its deps + login
            api.server_packet(env, "VG", "Boss;Tank,100,1;S,2,50,110")
            T.eq(env.Vanguard_Bar1.left:GetText(), "Tank")
        end)

    After each test every client it created must have no Lua errors (api.errors) and no
    errors swallowed by an addon's own pcall (api.pcall_errors); otherwise the test fails.
    T.known_bug(...) marks a test that documents a real addon bug: it is reported as XFAIL
    while the bug is there and turns into a FAIL once the bug is fixed (remove the marker then).
]]--

return function(api)
    local T = { tests = {}, broken_files = {} }

    local function where(level)
        local info = debug.getinfo((level or 2) + 1, "Sl")
        return info and (string.match(info.short_src, "[^/]+$") .. ":" .. info.currentline) or "?"
    end

    function T.test(name, fn) table.insert(T.tests, { name = name, fn = fn, file = T.current_file }) end
    function T.known_bug(name, bug, fn)
        table.insert(T.tests, { name = name, fn = fn, file = T.current_file, bug = bug })
    end
    function T.broken(file, err) table.insert(T.broken_files, { file = file, err = tostring(err) }) end

    -- assertions (raise with the caller's line)
    local function fail(msg, level) error(msg, (level or 2) + 1) end
    function T.ok(v, msg) if not v then fail(msg or "expected a true value", 2) end return v end
    function T.no(v, msg) if v then fail((msg or "expected a false value") .. " (got " .. tostring(v) .. ")", 2) end end
    function T.eq(a, b, msg)
        if a ~= b then fail((msg and (msg .. ": ") or "") .. "expected [" .. tostring(b) .. "], got [" .. tostring(a) .. "]", 2) end
    end
    function T.near(a, b, eps, msg)
        if type(a) ~= "number" or math.abs(a - b) > (eps or 1e-6) then
            fail((msg and (msg .. ": ") or "") .. "expected ~" .. tostring(b) .. ", got " .. tostring(a), 2)
        end
    end
    function T.has(hay, needle, msg)
        if type(hay) == "table" then hay = table.concat(hay, "\n") end
        if not hay or not string.find(hay, needle, 1, true) then
            fail((msg and (msg .. ": ") or "") .. "expected to find [" .. needle .. "] in:\n" .. tostring(hay), 2)
        end
    end
    function T.lacks(hay, needle, msg)
        if type(hay) == "table" then hay = table.concat(hay, "\n") end
        if hay and string.find(hay, needle, 1, true) then
            fail((msg and (msg .. ": ") or "") .. "did not expect [" .. needle .. "] in:\n" .. tostring(hay), 2)
        end
    end
    function T.shown(f, msg) if not (f and f:IsVisible()) then fail((msg or "frame") .. " should be visible", 2) end end
    function T.hidden(f, msg) if f and f:IsVisible() then fail((msg or "frame") .. " should be hidden", 2) end end

    -- Remove (and return) the errors of env matching a plain substring; fails if none match.
    function T.expect_error(env, needle)
        local kept, got = {}, {}
        for _, e in ipairs(env.__errors) do
            if string.find(e, needle, 1, true) then table.insert(got, e) else table.insert(kept, e) end
        end
        if not got[1] then fail("expected an error containing [" .. needle .. "]", 2) end
        for i = #env.__errors, 1, -1 do env.__errors[i] = nil end
        for _, e in ipairs(kept) do table.insert(env.__errors, e) end
        return got
    end

    -- clients ------------------------------------------------------------------
    local clients = {}
    function T.client(opts)
        opts = opts or {}
        opts.repo = opts.repo or api.repo
        local env = api.new_client(opts)
        table.insert(clients, env)
        return env
    end
    -- A client with the whole suite loaded and logged in.
    function T.suite(opts)
        local env = T.client(opts)
        api.load_suite(env)
        api.login(env)
        return env
    end
    -- A client with one addon (and its dependencies) loaded and logged in.
    function T.addon(name, opts)
        local env = T.client(opts)
        api.load_with_deps(env, name)
        api.login(env)
        return env
    end
    -- After api.relog the new client replaces the old one in the error check.
    function T.relog(env, extra)
        local new = api.relog(env, extra)
        for i, e in ipairs(clients) do if e == env then clients[i] = new end end
        return new
    end

    -- running ------------------------------------------------------------------
    local function firstLines(s, n)
        local out, i = {}, 0
        for l in string.gmatch(tostring(s), "[^\n]+") do
            i = i + 1
            if i > n then table.insert(out, "    ...") break end
            table.insert(out, (i == 1) and l or ("    " .. string.gsub(l, "^%s+", "")))
        end
        return table.concat(out, "\n")
    end

    local function runOne(t)
        clients = {}
        api.reset_bus()
        local ok, err = xpcall(t.fn, function(e)
            local msg = api.explain(e)
            local tb = debug.traceback("", 2)
            local keep = {}
            for l in string.gmatch(tb, "[^\n]+") do
                if string.find(l, "/tests/", 1, true) or string.find(l, "AddOns", 1, true) then
                    table.insert(keep, (string.gsub(l, "^%s+", "")))
                end
            end
            if keep[1] and not string.find(msg, "tests/", 1, true) then msg = msg .. "\n" .. table.concat(keep, "\n", 1, math.min(4, #keep)) end
            return msg
        end)
        local problems = {}
        if not ok then table.insert(problems, err) end
        for _, env in ipairs(clients) do
            for _, e in ipairs(env.__errors) do table.insert(problems, "[" .. env.__name .. "] " .. e) end
            if not env.__allow_pcall_errors then
                for _, e in ipairs(env.__pcall_errors) do table.insert(problems, "[" .. env.__name .. "] error swallowed by an addon pcall: " .. e) end
            end
        end
        return problems
    end

    function T.run(filter, verbose)
        local res = { pass = 0, fail = 0, xfail = 0, skipped = 0 }
        for _, b in ipairs(T.broken_files) do
            print("FAIL " .. b.file .. ": test file did not load: " .. b.err)
            res.fail = res.fail + 1
        end
        for _, t in ipairs(T.tests) do
            local hay = string.lower(t.name .. " " .. (t.file or ""))
            if filter and not string.find(hay, filter, 1, true) then
                res.skipped = res.skipped + 1
            else
                local t0 = os.clock()
                local problems = runOne(t)
                local dt = os.clock() - t0
                if dt > 0.25 and verbose then print(string.format("      (slow: %.2fs)", dt)) end
                if t.bug then
                    if problems[1] then
                        res.xfail = res.xfail + 1
                        print("XFAIL " .. t.name .. "  (known addon bug: " .. t.bug .. ")")
                        if verbose then print("      " .. firstLines(problems[1], 4)) end
                    else
                        res.fail = res.fail + 1
                        print("FAIL " .. t.name .. ": known bug no longer reproduces (" .. t.bug .. "); turn T.known_bug into T.test")
                    end
                elseif problems[1] then
                    res.fail = res.fail + 1
                    print("FAIL " .. t.name .. ": " .. firstLines(problems[1], 8))
                    for i = 2, math.min(4, #problems) do print("      also: " .. firstLines(problems[i], 3)) end
                    if #problems > 4 then print("      (+" .. (#problems - 4) .. " more)") end
                else
                    res.pass = res.pass + 1
                    print("PASS " .. t.name)
                end
                if verbose then
                    for _, env in ipairs(clients) do
                        local m = {}
                        for k in pairs(env.__unknown_methods) do table.insert(m, k) end
                        table.sort(m)
                        if m[1] then print("      [" .. env.__name .. "] unmodelled widget methods: " .. table.concat(m, " ")) end
                    end
                end
            end
        end
        return res
    end

    return T
end
