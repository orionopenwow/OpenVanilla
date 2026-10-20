--[[
    wow_api.lua - a fake 1.12.1 game environment for running the Classic+ addons outside the game.

        local api = dofile("devkit/sim/wow_api.lua")
        local env = api.new_client{ name = "Herald", class = "HUNTER", level = 12, repo = REPO }
        api.load_suite(env)              -- or api.load_addon(env, dir) / api.load_with_deps(env, "Threat")
        api.login(env)                   -- VARIABLES_LOADED, PLAYER_LOGIN, PLAYER_ENTERING_WORLD
        api.server_packet(env, "VG", "Ragnaros;Brakkus,100,1;Herald,80,0;S,2,80,110")
        api.tick(env, 2)                 -- OnUpdate scripts, arg1 = elapsed, chat delivered between steps
        env.__slash("/threat")
        assert(api.errors(env)[1] == nil)

    Each client is a sandbox table used as the addons' global environment (setfenv). Frames are
    permissive: a real 1.12 widget method the fake does not model is a silent no-op, a method that
    does not exist in 1.12 is nil (exactly what the real client does). Reading an unknown global
    returns nil; calling it fails with "fake API missing: <name>" and says whether the name is a
    real 1.12 function (the fake needs it) or not (the addon has a bug). Script errors never stop
    the sim; they are collected per client (api.errors), as the real client would show them.

    Lua 5.0 shape: string/math/table expose only the 1.12 library functions (no string.gmatch,
    string.match, math.fmod, table.maxn ...), the WoW globals (strfind, tinsert, getn, mod, ...)
    exist, and names that only later clients have (hooksecurefunc, select, C_Timer, print ...) are nil.
    Every addon file is scanned by lua50_guard.lua before it runs.
]]--

local api = {}

local HERE = string.match(debug.getinfo(1, "S").source, "^@(.*[/\\])") or "./"
api.HERE = HERE
api.guard = dofile(HERE .. "lua50_guard.lua")

-- --------------------------------------------------------------------------------------------
-- Reference data (vendored from the wenilla 1.12 reference tables, see data/)
-- --------------------------------------------------------------------------------------------

local function readList(path)
    local out = {}
    local f = io.open(path, "r")
    if not f then return out end
    for l in f:lines() do
        if l ~= "" and string.sub(l, 1, 1) ~= "#" then
            local name, extra = string.match(l, "^([^\t]+)\t?(.*)$")
            out[name] = (extra ~= "" and extra) or true
        end
    end
    f:close()
    return out
end

api.REAL_GLOBALS = readList(HERE .. "data/globals_112.tsv")       -- name -> origin
api.WIDGET_METHODS = readList(HERE .. "data/widget_methods_112.txt")
api.EVENTS = readList(HERE .. "data/events_112.txt")

-- Names that do not exist in 1.12 but that addons written for later clients feature-test.
-- They are forced to nil in every client so "if hooksecurefunc then" takes the 1.12 path.
api.NIL_GLOBALS = {
    "hooksecurefunc", "select", "C_Timer", "print", "strsplit", "strjoin", "strtrim", "strmatch",
    "wipe", "tContains", "UnitGUID", "UnitAura", "GetSpellInfo", "InCombatLockdown",
    "GetNumGroupMembers", "IsInGroup", "IsInRaid", "RegisterAddonMessagePrefix", "C_ChatInfo",
    "Ambiguate", "CombatLogGetCurrentEventInfo", "CreateFramePool", "Mixin", "CreateFromMixins",
    "coroutine", "require", "dofile", "loadfile", "load", "io", "os", "debug", "module",
    "newproxy", "rawlen", "bit32", "utf8", "GetCursorInfo", "CloseSpecialWindows",
}
local NIL_SET = {}
for _, n in ipairs(api.NIL_GLOBALS) do NIL_SET[n] = true end

-- Lua 5.0 strings have no methods: ("x"):upper() fails there. Method calls made by code running
-- in a sim client (its environment has __base) fail the same way; the harness is unaffected.
do
    local mt = getmetatable("")
    local lib = string
    if mt and not api.__stringGuard then
        api.__stringGuard = true
        mt.__index = function(_, k)
            local info = debug.getinfo(2, "f")
            if info and info.func then
                local ok, fenv = pcall(getfenv, info.func)
                if ok and type(fenv) == "table" and rawget(fenv, "__base") then
                    error("Lua 5.0 strings have no methods: s:" .. tostring(k) .. "() works only in Lua 5.1 (use string." .. tostring(k) .. "(s, ...))", 2)
                end
            end
            return lib[k]
        end
    end
end

-- --------------------------------------------------------------------------------------------
-- Small utilities
-- --------------------------------------------------------------------------------------------

local function NOOP() end

local function shallow(t) local o = {} for k, v in pairs(t or {}) do o[k] = v end return o end

local function deepcopy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local o = {}
    seen[v] = o
    for k, x in pairs(v) do
        if type(x) ~= "function" and type(k) ~= "function" then o[deepcopy(k, seen)] = deepcopy(x, seen) end
    end
    return o
end
api.deepcopy = deepcopy

local function fileExists(p) local f = io.open(p, "r") if f then f:close() return true end return false end

local function listDir(dir)
    -- a host without `ls` (Forge on Windows) passes its own lister in SIM_LIST_DIR
    local hook = rawget(_G, "SIM_LIST_DIR")
    if hook then return hook(dir) end
    local out = {}
    local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
    if p then for l in p:lines() do table.insert(out, l) end p:close() end
    return out
end
api.list_dir = listDir

-- Text as the player sees it: colour codes removed, "||" shown as "|".
function api.visible(s)
    if s == nil then return nil end
    s = tostring(s)
    s = string.gsub(s, "||", "\1")
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")
    s = string.gsub(s, "|r", "")
    s = string.gsub(s, "\1", "|")
    return s
end

-- Turns a raw Lua error into something a test author can act on.
function api.explain(msg)
    msg = tostring(msg)
    local name = string.match(msg, "attempt to call global '([%w_]+)' %(a nil value%)")
    if name then
        if NIL_SET[name] then
            return "1.12 has no " .. name .. " (addon bug: post-1.12 API): " .. msg
        elseif api.REAL_GLOBALS[name] then
            return "fake API missing: " .. name .. " (real 1.12 " .. tostring(api.REAL_GLOBALS[name])
                .. " function; add it to wow_api.lua): " .. msg
        end
        return "fake API missing: " .. name .. " (not a 1.12 global either; probably an addon bug): " .. msg
    end
    local field = string.match(msg, "attempt to call field '([%w_]+)' %(a nil value%)")
    if field == "gmatch" or field == "match" or field == "fmod" or field == "maxn" or field == "reverse" then
        return msg .. "  [" .. field .. " is a Lua 5.1 library function; the 1.12 client runs Lua 5.0]"
    end
    local method = string.match(msg, "attempt to call method '([%w_]+)' %(a nil value%)")
    if method and not api.WIDGET_METHODS[method] then
        return msg .. "  [" .. method .. " is not a 1.12 widget method]"
    end
    return msg
end

local function traceback(err)
    local tb = debug.traceback("", 2)
    -- keep the frames that point into addon code or tests, drop the harness plumbing
    local keep = {}
    for l in string.gmatch(tb, "[^\n]+") do
        if string.find(l, "AddOns", 1, true) or string.find(l, "/tests/", 1, true) then
            table.insert(keep, "    " .. string.gsub(l, "^%s+", ""))
        end
    end
    local out = api.explain(err)
    if keep[1] then out = out .. "\n" .. table.concat(keep, "\n", 1, math.min(6, #keep)) end
    return out
end
api.traceback = traceback

function api.record_error(env, err, where)
    local msg = (where and (where .. ": ") or "") .. api.explain(err)
    table.insert(env.__errors, msg)
    return msg
end

function api.errors(env) return env.__errors end
function api.pcall_errors(env) return env.__pcall_errors end

-- --------------------------------------------------------------------------------------------
-- Widget objects
-- --------------------------------------------------------------------------------------------

local ST = setmetatable({}, { __mode = "k" })    -- object -> internal state
api.ST = ST
function api.state(o) return ST[o] end

local M = {}                                      -- methods shared by every widget type
local OBJ_MT = {
    __index = function(o, k)
        local m = M[k]
        if m then return m end
        if type(k) == "string" and api.WIDGET_METHODS[k] then
            local s = ST[o]
            if s then s.env.__unknown_methods[k] = true end
            return NOOP                           -- real 1.12 method, not modelled
        end
        return nil                                -- not a 1.12 method: nil, like the real client
    end,
}

local FRAME_TYPES = {
    Frame = true, Button = true, CheckButton = true, EditBox = true, StatusBar = true, ScrollFrame = true,
    Slider = true, GameTooltip = true, MessageFrame = true, ScrollingMessageFrame = true, Model = true,
    PlayerModel = true, ColorSelect = true, SimpleHTML = true, Minimap = true, DressUpModel = true,
    TabardModel = true, Cooldown = true, LootButton = true,
}
local TEMPLATES = {
    UIPanelButtonTemplate = "button", UIPanelButtonTemplate2 = "button", UIPanelCloseButton = "button",
    GameMenuButtonTemplate = "button", OptionsButtonTemplate = "button", UICheckButtonTemplate = "check",
    OptionsCheckButtonTemplate = "check", InputBoxTemplate = "input", UIPanelScrollFrameTemplate = "scroll",
    GameTooltipTemplate = "tooltip", OptionsSliderTemplate = "slider",
}

local function newObject(env, otype, name, parent, isRegion)
    local o = setmetatable({}, OBJ_MT)
    local s = {
        env = env, otype = otype, name = name, parent = parent, children = {}, regions = {},
        shown = true, scripts = {}, events = {}, points = {}, w = 0, h = 0, alpha = 1, scale = 1,
        isRegion = isRegion, enabled = true, strata = "MEDIUM",
    }
    ST[o] = s
    if parent and ST[parent] then
        local ps = ST[parent]
        if isRegion then table.insert(ps.regions, o) else table.insert(ps.children, o) end
        s.level = (ps.level or 0) + 1
        s.strata = ps.strata
    else
        s.level = 1
    end
    if name then rawset(env, name, o) end
    if isRegion then table.insert(env.__regions, o) else table.insert(env.__frames, o) end
    return o
end
api.new_object = newObject

local function isVisible(o)
    local s = ST[o]
    while s do
        if not s.shown then return false end
        if not s.parent then return true end
        s = ST[s.parent]
    end
    return true
end
api.is_visible = isVisible

-- Runs one script handler the way the client does: 'this' (and for events 'event'/argN) set
-- as globals; errors are recorded on the client and never escape.
local function runScript(o, which, args, ev)
    local s = ST[o]
    local f = s and s.scripts[which]
    if not f then return end
    local env = s.env
    local save = { rawget(env, "this"), rawget(env, "event") }
    for i = 1, 9 do save[i + 2] = rawget(env, "arg" .. i) end
    rawset(env, "this", o)
    if ev then rawset(env, "event", ev) end
    if args then for i = 1, 9 do rawset(env, "arg" .. i, args[i]) end end
    local ok, err = xpcall(f, traceback)
    rawset(env, "this", save[1]); rawset(env, "event", save[2])
    for i = 1, 9 do rawset(env, "arg" .. i, save[i + 2]) end
    if not ok then
        table.insert(env.__errors, which .. " of " .. (s.name or ("<" .. s.otype .. ">")) .. (ev and (" (" .. ev .. ")") or "") .. ": " .. err)
    end
end
api.run_script = runScript

local function fireShow(o)
    runScript(o, "OnShow")
    for _, c in ipairs(ST[o].children) do if ST[c].shown then fireShow(c) end end
end
local function fireHide(o)
    runScript(o, "OnHide")
    for _, c in ipairs(ST[o].children) do if ST[c].shown then fireHide(c) end end
end

-- identity & hierarchy
function M:GetName() return ST[self].name end
function M:GetParent() return ST[self].parent end
function M:SetParent(p)
    local s = ST[self]
    if s.parent and ST[s.parent] then
        local list = s.isRegion and ST[s.parent].regions or ST[s.parent].children
        for i, c in ipairs(list) do if c == self then table.remove(list, i) break end end
    end
    s.parent = p
    if p and ST[p] then table.insert(s.isRegion and ST[p].regions or ST[p].children, self) end
end
function M:GetObjectType() return ST[self].otype end
function M:IsObjectType(t) return ST[self].otype == t and 1 or nil end
function M:IsFrameType(t) return ST[self].otype == t and 1 or nil end
function M:GetChildren() return unpack(ST[self].children) end
function M:GetNumChildren() return #ST[self].children end
function M:GetRegions() return unpack(ST[self].regions) end
function M:GetNumRegions() return #ST[self].regions end
function M:GetID() return ST[self].id or 0 end
function M:SetID(i) ST[self].id = i end

-- visibility
function M:Show()
    local s = ST[self]
    if s.shown then return end
    s.shown = true
    if not s.isRegion and (not s.parent or isVisible(s.parent)) then fireShow(self) end
end
function M:Hide()
    local s = ST[self]
    if not s.shown then return end
    local was = isVisible(self)
    s.shown = false
    if was and not s.isRegion then fireHide(self) end
end
function M:IsShown() return ST[self].shown and 1 or nil end
function M:IsVisible() return isVisible(self) and 1 or nil end

-- scripts & events
function M:SetScript(which, f)
    local s = ST[self]
    s.scripts[which] = f
    if which == "OnUpdate" and f and not s.inUpdateList then
        s.inUpdateList = true
        table.insert(s.env.__onupdate, self)
    end
end
function M:GetScript(which) return ST[self].scripts[which] end
function M:HasScript(which) return 1 end
function M:RegisterEvent(ev)
    local s = ST[self]
    if not api.EVENTS[ev] then
        table.insert(s.env.__errors, "RegisterEvent(\"" .. tostring(ev) .. "\") on " .. (s.name or s.otype)
            .. ": not a 1.12 event")
    end
    if not s.events[ev] then
        s.events[ev] = true
        local list = s.env.__evreg[ev]
        if not list then list = {} s.env.__evreg[ev] = list end
        table.insert(list, self)
    end
end
function M:UnregisterEvent(ev)
    local s = ST[self]
    s.events[ev] = nil
    local list = s.env.__evreg[ev]
    if list then for i, f in ipairs(list) do if f == self then table.remove(list, i) break end end end
end
function M:RegisterAllEvents() ST[self].allEvents = true; table.insert(ST[self].env.__allevents, self) end
function M:UnregisterAllEvents()
    local s = ST[self]
    for ev in pairs(s.events) do M.UnregisterEvent(self, ev) end
    s.allEvents = nil
end
function M:IsEventRegistered(ev) return ST[self].events[ev] and 1 or nil end

-- geometry (tracked, not computed: enough for code that reads back what it set)
function M:SetWidth(w) ST[self].w = tonumber(w) or 0 end
function M:SetHeight(h) ST[self].h = tonumber(h) or 0 end
function M:GetWidth() return ST[self].w end
function M:GetHeight()
    local s = ST[self]
    if s.otype == "FontString" and (s.h or 0) == 0 then
        local _, nl = string.gsub(s.text or "", "\n", "")
        return (s.text and s.text ~= "") and (nl + 1) * 12 or 0
    end
    return s.h
end
function M:SetPoint(p, rel, rp, x, y)
    local s = ST[self]
    if type(rel) == "number" then rel, rp, x, y = nil, nil, rel, rp end
    if type(rel) == "string" then rel = s.env[rel] end
    table.insert(s.points, { p, rel, rp or p, x or 0, y or 0 })
    if (p == "TOPLEFT" or p == "LEFT" or p == "BOTTOMLEFT") and type(x) == "number" then s.left = x end
    if (p == "TOPLEFT" or p == "TOP" or p == "TOPRIGHT") and type(y) == "number" then s.top = y end
end
function M:ClearAllPoints() ST[self].points = {} end
function M:SetAllPoints(rel) local s = ST[self]; s.points = { { "TOPLEFT", rel, "TOPLEFT", 0, 0 }, { "BOTTOMRIGHT", rel, "BOTTOMRIGHT", 0, 0 } } end
function M:GetNumPoints() return #ST[self].points end
function M:GetPoint(i) local p = ST[self].points[i or 1]; if p then return p[1], p[2], p[3], p[4], p[5] end end
function M:GetLeft() return ST[self].left or 0 end
function M:GetTop() return ST[self].top or 768 end
function M:GetRight() local s = ST[self]; return (s.left or 0) + (s.w or 0) end
function M:GetBottom() local s = ST[self]; return (s.top or 768) - (s.h or 0) end
function M:GetCenter() local s = ST[self]; return (s.left or 0) + (s.w or 0) / 2, (s.top or 768) - (s.h or 0) / 2 end
function M:SetScale(x) ST[self].scale = x end
function M:GetScale() return ST[self].scale end
function M:GetEffectiveScale() return ST[self].scale end
function M:SetAlpha(a) ST[self].alpha = tonumber(a) or 1 end
function M:GetAlpha() return ST[self].alpha end
function M:SetFrameLevel(l) ST[self].level = l end
function M:GetFrameLevel() return ST[self].level or 1 end
function M:SetFrameStrata(s) ST[self].strata = s end
function M:GetFrameStrata() return ST[self].strata end

-- regions
function M:CreateTexture(name, layer)
    local t = newObject(ST[self].env, "Texture", name, self, true)
    ST[t].layer = layer
    return t
end
function M:CreateFontString(name, layer, inherits)
    local t = newObject(ST[self].env, "FontString", name, self, true)
    ST[t].layer, ST[t].font = layer, inherits
    return t
end

local tooltipText   -- defined with the tooltip methods below

-- text (FontString, Button, EditBox)
local function utf8len(s) local _, n = string.gsub(s, "[^\128-\191]", "") return n end
local function utf8clip(s, n)
    local count, i = 0, 1
    while i <= #s do
        local b = string.byte(s, i)
        if b < 128 or b >= 192 then count = count + 1; if count > n then return string.sub(s, 1, i - 1) end end
        i = i + 1
    end
    return s
end
function M:SetText(t, r, g, b)
    local s = ST[self]
    if s.otype == "GameTooltip" then return tooltipText(self, t, r, g, b) end
    if t ~= nil then t = tostring(t) end
    if s.otype == "Button" or s.otype == "CheckButton" then
        if not s.fontString then s.fontString = M.CreateFontString(self) end
        M.SetText(s.fontString, t)
        s.text = t
        return
    end
    if s.otype == "EditBox" then
        t = t or ""
        if s.maxLetters and s.maxLetters > 0 and utf8len(t) > s.maxLetters then t = utf8clip(t, s.maxLetters) end
        s.text = t
        runScript(self, "OnTextChanged")
        return
    end
    s.text = t
end
function M:GetText()
    local s = ST[self]
    if s.otype == "EditBox" then return s.text or "" end
    if s.text == "" then return nil end
    return s.text
end
function M:GetFontString() local s = ST[self]; if not s.fontString then s.fontString = M.CreateFontString(self) end return s.fontString end
function M:SetFontString(fs) ST[self].fontString = fs end
function M:GetStringWidth() return utf8len(api.visible(ST[self].text or "")) * 6 end
function M:GetTextWidth() return M.GetStringWidth(self) end
function M:GetTextHeight() return 12 end
function M:SetJustifyH(j) ST[self].justifyH = j end
function M:SetJustifyV(j) ST[self].justifyV = j end
function M:GetJustifyH() return ST[self].justifyH or "CENTER" end
function M:SetTextColor(r, g, b, a) ST[self].textColor = { r, g, b, a or 1 } end
function M:GetTextColor() local c = ST[self].textColor or { 1, 1, 1, 1 }; return c[1], c[2], c[3], c[4] end
function M:SetFont(path, size, flags) ST[self].fontPath = { path, size, flags }; return 1 end
function M:GetFont() local f = ST[self].fontPath or { "Fonts\\FRIZQT__.TTF", 12, "" }; return f[1], f[2], f[3] end
function M:SetFontObject(o) ST[self].font = o end
function M:GetFontObject() return ST[self].font end

-- textures
local function artExists(env, path)
    local low = string.lower(path)
    if string.sub(low, 1, 17) ~= "interface\\addons\\" and string.sub(low, 1, 22) ~= "interface\\classicplus\\" then
        return true                               -- stock game file: assume the client has it
    end
    local mode = env.__art
    if mode == true then return true end
    if type(mode) == "function" then return mode(path) and true or false end   -- opts.art = function(path)
    if mode == false or not env.__repo then return false end
    local rel = string.gsub(path, "\\", "/")
    local dir, base = string.match(rel, "^(.*)/([^/]+)$")
    if not dir then return false end              -- a folder, not a file
    dir = env.__repo .. "/Data/" .. dir
    local cache = api.__dircache[dir]
    if not cache then
        cache = {}
        for _, f in ipairs(listDir(dir)) do cache[string.lower(f)] = true end
        api.__dircache[dir] = cache
    end
    local b = string.lower(base)
    if string.find(b, "%.%a%a%a$") then return cache[b] or false end
    return cache[b .. ".tga"] or cache[b .. ".blp"] or false
end
api.__dircache = {}

function M:SetTexture(a, g, b, al)
    local s = ST[self]
    if type(a) == "number" then
        s.texture, s.color = nil, { a, g, b, al or 1 }
        return 1
    end
    s.color = nil
    if a == nil then s.texture = nil return nil end
    if artExists(s.env, a) then s.texture = a; return 1 end
    s.env.__missing_art[a] = true
    s.texture = nil
    return nil
end
function M:GetTexture() return ST[self].texture end
function M:SetTexCoord(...) ST[self].texcoord = { ... } end
function M:GetTexCoord() local t = ST[self].texcoord or { 0, 1, 0, 1 }; return unpack(t) end
function M:SetVertexColor(r, g, b, a) ST[self].vertex = { r, g, b, a or 1 } end
function M:GetVertexColor() local c = ST[self].vertex or { 1, 1, 1, 1 }; return c[1], c[2], c[3], c[4] end
function M:SetBlendMode(m) ST[self].blend = m end
function M:GetBlendMode() return ST[self].blend or "BLEND" end
function M:SetDesaturated(d) ST[self].desat = d and 1 or nil; return 1 end
function M:IsDesaturated() return ST[self].desat end
for _, k in ipairs({ "Normal", "Pushed", "Highlight", "Disabled", "Checked" }) do
    M["Set" .. k .. "Texture"] = function(self, t)
        local s = ST[self]
        if type(t) == "string" then
            local tex = M.CreateTexture(self); M.SetTexture(tex, t); s[k] = tex
        else s[k] = t end
    end
    M["Get" .. k .. "Texture"] = function(self) return ST[self][k] end
end

-- backdrops: kept (not drawn) so devkit/sim/render can draw what the client would
function M:SetBackdrop(b) ST[self].backdrop = b end
function M:GetBackdrop() return ST[self].backdrop end
function M:SetBackdropColor(r, g, b, a) ST[self].backdropColor = { r, g, b, a or 1 } end
function M:GetBackdropColor() local c = ST[self].backdropColor or { 1, 1, 1, 1 }; return c[1], c[2], c[3], c[4] end
function M:SetBackdropBorderColor(r, g, b, a) ST[self].backdropBorder = { r, g, b, a or 1 } end
function M:GetBackdropBorderColor() local c = ST[self].backdropBorder or { 1, 1, 1, 1 }; return c[1], c[2], c[3], c[4] end

-- models: what a DressUpModel shows (SetUnit/Dress = the unit as it is, Undress = bare, TryOn
-- adds an item). api.model_items(o) lists the items tried on since the last reset, in order.
function M:Dress() local s = ST[self]; s.dressed = true; s.tried = {} end
function M:Undress() local s = ST[self]; s.dressed = false; s.tried = {} end
function M:TryOn(id)
    local s = ST[self]
    s.tried = s.tried or {}
    local n = tonumber(id) or tonumber(string.match(tostring(id), "item:(%d+)"))
    if n and n > 0 then table.insert(s.tried, n) end
end
function M:SetRotation(r) ST[self].rotation = tonumber(r) or 0 end
function M:SetPosition(x, y, z) local s = ST[self]; s.pos = { x, y, z } end
function api.model_items(o) local s = ST[o]; return (s and s.tried) or {} end
function api.model_dressed(o) local s = ST[o]; return s and s.dressed end

-- status bars & sliders
function M:SetMinMaxValues(a, b) local s = ST[self]; s.min, s.max = tonumber(a) or 0, tonumber(b) or 0 end
function M:GetMinMaxValues() local s = ST[self]; return s.min or 0, s.max or 1 end
function M:SetValue(v)
    local s = ST[self]
    v = tonumber(v) or 0
    if s.min and v < s.min then v = s.min end
    if s.max and v > s.max then v = s.max end
    s.value = v
end
function M:GetValue() return ST[self].value or 0 end
function M:SetStatusBarTexture(t)
    local s = ST[self]
    if type(t) == "string" then
        if not s.barTexture then s.barTexture = M.CreateTexture(self, nil, "ARTWORK") end
        M.SetTexture(s.barTexture, t)
    else s.barTexture = t end
end
function M:GetStatusBarTexture() return ST[self].barTexture end
function M:SetStatusBarColor(r, g, b, a) ST[self].barColor = { r, g, b, a or 1 } end
function M:GetStatusBarColor() local c = ST[self].barColor or { 1, 1, 1, 1 }; return c[1], c[2], c[3], c[4] end

-- buttons
function M:Enable() ST[self].enabled = true end
function M:Disable() ST[self].enabled = false end
function M:IsEnabled() return ST[self].enabled and 1 or nil end
function M:SetChecked(v) ST[self].checked = (v and v ~= 0) and 1 or nil end
function M:GetChecked() return ST[self].checked end
function M:LockHighlight() ST[self].lockedHighlight = true end
function M:UnlockHighlight() ST[self].lockedHighlight = false end
function M:Click(button) api.click(self, button, true) end

-- edit boxes
function M:SetMaxLetters(n) ST[self].maxLetters = tonumber(n) end
function M:GetMaxLetters() return ST[self].maxLetters or 0 end
function M:SetNumeric(v) ST[self].numeric = v end
function M:IsNumeric() return ST[self].numeric and 1 or nil end
function M:GetNumber() return tonumber(ST[self].text or "") or 0 end
function M:SetNumber(n) M.SetText(self, tostring(n)) end
function M:SetMultiLine(v) ST[self].multiLine = v end
function M:IsMultiLine() return ST[self].multiLine and 1 or nil end
function M:SetFocus() ST[self].env.__focus = self end
function M:ClearFocus() local env = ST[self].env; if env.__focus == self then env.__focus = nil end end
function M:Insert(t) local s = ST[self]; M.SetText(self, (s.text or "") .. tostring(t or "")) end
function M:GetNumLetters() return utf8len(ST[self].text or "") end

-- scroll frames
function M:SetScrollChild(c) ST[self].scrollChild = c end
function M:GetScrollChild() return ST[self].scrollChild end
function M:SetVerticalScroll(v) ST[self].vscroll = v end
function M:GetVerticalScroll() return ST[self].vscroll or 0 end
function M:GetVerticalScrollRange() return 0 end

-- message frames (chat frames, UIErrorsFrame)
function M:AddMessage(text, r, g, b)
    local s = ST[self]
    s.messages = s.messages or {}
    table.insert(s.messages, tostring(text))
    if s.isChat then table.insert(s.env.__chat, tostring(text)) end
end
function M:Clear() ST[self].messages = {} end
-- scroll position of a message frame, in lines up from the newest (as 1.12's GetCurrentScroll)
function M:GetNumMessages() return #(ST[self].messages or {}) end
function M:GetCurrentScroll() return ST[self].scroll or 0 end
function M:ScrollUp() local s = ST[self]; s.scroll = math.min((s.scroll or 0) + 1, math.max(0, #(s.messages or {}) - 1)) end
function M:ScrollDown() local s = ST[self]; s.scroll = math.max(0, (s.scroll or 0) - 1) end
function M:ScrollToTop() local s = ST[self]; s.scroll = math.max(0, #(s.messages or {}) - 1) end
function M:ScrollToBottom() ST[self].scroll = 0 end
function M:AtBottom() return (ST[self].scroll or 0) == 0 and 1 or nil end
function M:AtTop() local s = ST[self]; return (s.scroll or 0) >= math.max(0, #(s.messages or {}) - 1) and 1 or nil end

-- tooltips: lines live in <Name>TextLeftN / <Name>TextRightN font strings, like the real one
local function tipLine(tip, side, i)
    local s = ST[tip]
    local name = (s.name or "Tooltip") .. "Text" .. side .. i
    local fs = s.env[name]
    if not fs or not ST[fs] then fs = newObject(s.env, "FontString", name, tip, true) end
    return fs
end
function M:ClearLines()
    local s = ST[self]
    for i = 1, (s.numLines or 0) do
        M.SetText(tipLine(self, "Left", i), nil); M.SetText(tipLine(self, "Right", i), nil)
    end
    s.numLines = 0
end
function M:AddLine(text, r, g, b)
    local s = ST[self]
    s.numLines = (s.numLines or 0) + 1
    local l = tipLine(self, "Left", s.numLines)
    M.SetText(l, text); M.SetTextColor(l, r or 1, g or 0.82, b or 0)
    M.SetText(tipLine(self, "Right", s.numLines), nil)
end
function M:AddDoubleLine(left, right, r1, g1, b1, r2, g2, b2)
    M.AddLine(self, left, r1, g1, b1)
    local s = ST[self]
    M.SetText(tipLine(self, "Right", s.numLines), right)
end
function M:NumLines() return ST[self].numLines or 0 end
function M:SetOwner(owner, anchor)
    local s = ST[self]
    s.owner, s.anchor = owner, anchor
    M.ClearLines(self)
end
function M:IsOwned(f) return ST[self].owner == f and 1 or nil end
tooltipText = function(self, text, r, g, b)    -- the tooltip's SetText: one line, replaces the rest
    M.ClearLines(self)
    M.AddLine(self, text, r, g, b)
end
local function itemTooltip(tip, id)
    local env = ST[tip].env
    local it = id and api.item(env, id)
    M.ClearLines(tip)
    if not it then return nil end
    M.AddLine(tip, "|c" .. api.QUALITY_HEX[it.quality or 1] .. it.name .. "|r")
    if it.binds then M.AddLine(tip, it.binds, 1, 1, 1) end
    for _, l in ipairs(it.lines or {}) do M.AddLine(tip, l, 1, 1, 1) end   -- e.g. { "Chest", "120 Armor", "+5 Stamina" }
    M.Show(tip)
    return 1
end
local function linkId(link) return tonumber(string.match(link or "", "item:(%d+)")) end
function M:SetUnit(unit)
    local ms = ST[self]
    if ms.otype == "DressUpModel" or ms.otype == "PlayerModel" or ms.otype == "Model" or ms.otype == "TabardModel" then
        ms.unit = unit; ms.dressed = true; ms.tried = {}           -- a model: the unit as it is
        return
    end
    local env = ST[self].env
    M.ClearLines(self)
    local u = api.unit(env, unit)
    if not u then return end
    M.AddLine(self, u.name, 1, 1, 1)
    local cls = u.isPlayer and (" " .. (api.CLASS_NAMES[u.class or ""] or "")) or ""
    M.AddLine(self, "Level " .. (u.level or 1) .. " " .. (u.isPlayer and (u.race or "") or (u.creature or "Humanoid")) .. cls
        .. (u.isPlayer and " (Player)" or ""), 1, 1, 1)
    M.Show(self)
end
function M:SetBagItem(bag, slot) local it = api.bag_slot(ST[self].env, bag, slot); return itemTooltip(self, it and it.id) end
function M:SetInventoryItem(unit, slot)
    local env = ST[self].env
    local id = env.__inventory[slot]
    if not id and slot and slot >= 40 then local it = api.bag_slot(env, -1, slot - 39); id = it and it.id end
    return itemTooltip(self, id)
end
function M:SetHyperlink(link) return itemTooltip(self, linkId(link)) end
function M:SetMerchantItem(i)
    local m = ST[self].env.__merchant
    return itemTooltip(self, m and m.items[i] and m.items[i].id)
end
function M:SetLootItem(i) local l = ST[self].env.__loot[i]; return itemTooltip(self, l and l.id) end
function M:SetAuctionItem(kind, i) local a = ST[self].env.__auctions[i]; return itemTooltip(self, a and a.id) end
function M:SetQuestLogItem(kind, i)
    local env = ST[self].env
    local q = env.__questlog_selected and env.__questlog_selected()
    local r = q and (kind == "choice" and q.choices or q.rewards)
    return itemTooltip(self, r and r[i] and (r[i].id or r[i][1]))
end

-- clicks / mouse (also used as api helpers)
function api.click(o, button, force)
    local s = ST[o]
    assert(s, "api.click: not a widget")
    if not force and not isVisible(o) then error("api.click: " .. (s.name or s.otype) .. " is not visible", 2) end
    if not s.enabled then return false end
    if s.otype == "CheckButton" then s.checked = (not s.checked) and 1 or nil end
    runScript(o, "OnClick", { button or "LeftButton" })
    return true
end
function api.enter(o) runScript(o, "OnEnter") end
function api.leave(o) runScript(o, "OnLeave") end
function api.wheel(o, delta) runScript(o, "OnMouseWheel", { delta }) end
-- Typing into an edit box: SetText fires OnTextChanged.
function api.type(o, text) M.SetText(o, text) end
function api.press_enter(o) runScript(o, "OnEnterPressed") end

-- --------------------------------------------------------------------------------------------
-- Static game data
-- --------------------------------------------------------------------------------------------

api.CLASS_NAMES = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
    SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}
api.RACE_FILES = {
    Human = "Human", Dwarf = "Dwarf", ["Night Elf"] = "NightElf", Gnome = "Gnome",
    Orc = "Orc", Undead = "Scourge", Tauren = "Tauren", Troll = "Troll",
}
api.QUALITY_HEX = { [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ff1eff00", [3] = "ff0070dd", [4] = "ffa335ee", [5] = "ffff8000" }

-- A few real items; tests add their own with api.add_item(env, {...}).
api.ITEMS = {
    [2589] = { name = "Linen Cloth", quality = 1, icon = "Interface\\Icons\\INV_Fabric_Linen_01", sell = 13, stack = 20, type = "Trade Goods" },
    [2770] = { name = "Copper Ore", quality = 1, icon = "Interface\\Icons\\INV_Ore_Copper_01", sell = 5, stack = 20, type = "Trade Goods" },
    [6948] = { name = "Hearthstone", quality = 1, icon = "Interface\\Icons\\INV_Misc_Rune_01", sell = 0, stack = 1, type = "Miscellaneous" },
    [7073] = { name = "Broken Fang", quality = 0, icon = "Interface\\Icons\\INV_Misc_Bone_08", sell = 6, stack = 5, type = "Junk" },
    [7074] = { name = "Chipped Claw", quality = 0, icon = "Interface\\Icons\\INV_Misc_Bone_07", sell = 4, stack = 5, type = "Junk" },
    [4306] = { name = "Silk Cloth", quality = 1, icon = "Interface\\Icons\\INV_Fabric_Silk_01", sell = 150, stack = 20, type = "Trade Goods" },
    [2318] = { name = "Light Leather", quality = 1, icon = "Interface\\Icons\\INV_Misc_LeatherScrap_03", sell = 15, stack = 10, type = "Trade Goods" },
    [858] = { name = "Lesser Healing Potion", quality = 1, icon = "Interface\\Icons\\INV_Potion_52", sell = 25, stack = 5, type = "Consumable" },
    [2575] = { name = "Red Linen Shirt", quality = 1, icon = "Interface\\Icons\\INV_Shirt_Red_01", sell = 15, stack = 1, type = "Armor" },
    [1203] = { name = "Aegis of Stormwind", quality = 3, icon = "Interface\\Icons\\INV_Shield_06", sell = 4210, stack = 1, type = "Armor", binds = "Binds when picked up" },
    [19019] = { name = "Thunderfury, Blessed Blade of the Windseeker", quality = 5, icon = "Interface\\Icons\\INV_Sword_39", sell = 255355, stack = 1, type = "Weapon" },
}

-- enUS GlobalStrings the suite reads with getglobal (combat log formats and a few labels).
api.GLOBAL_STRINGS = {
    SPELLLOGCRITSCHOOLSELFOTHER = "Your %s crits %s for %d %s damage.",
    SPELLLOGSCHOOLSELFOTHER = "Your %s hits %s for %d %s damage.",
    SPELLLOGCRITSELFOTHER = "Your %s crits %s for %d.",
    SPELLLOGSELFOTHER = "Your %s hits %s for %d.",
    COMBATHITCRITSCHOOLSELFOTHER = "You crit %s for %d %s damage.",
    COMBATHITSCHOOLSELFOTHER = "You hit %s for %d %s damage.",
    COMBATHITCRITSELFOTHER = "You crit %s for %d.",
    COMBATHITSELFOTHER = "You hit %s for %d.",
    PERIODICAURADAMAGESELFOTHER = "%s suffers %d %s damage from your %s.",
    SPELLLOGCRITSCHOOLOTHEROTHER = "%s's %s crits %s for %d %s damage.",
    SPELLLOGSCHOOLOTHEROTHER = "%s's %s hits %s for %d %s damage.",
    SPELLLOGCRITOTHEROTHER = "%s's %s crits %s for %d.",
    SPELLLOGOTHEROTHER = "%s's %s hits %s for %d.",
    PERIODICAURADAMAGEOTHEROTHER = "%s suffers %d %s damage from %s's %s.",
    COMBATHITCRITSCHOOLOTHEROTHER = "%s crits %s for %d %s damage.",
    COMBATHITSCHOOLOTHEROTHER = "%s hits %s for %d %s damage.",
    COMBATHITCRITOTHEROTHER = "%s crits %s for %d.",
    COMBATHITOTHEROTHER = "%s hits %s for %d.",
    HEALEDCRITSELFSELF = "Your %s critically heals you for %d.",
    HEALEDSELFSELF = "Your %s heals you for %d.",
    HEALEDCRITSELFOTHER = "Your %s critically heals %s for %d.",
    HEALEDSELFOTHER = "Your %s heals %s for %d.",
    HEALEDCRITOTHERSELF = "%s's %s critically heals you for %d.",
    HEALEDOTHERSELF = "%s's %s heals you for %d.",
    HEALEDCRITOTHEROTHER = "%s's %s critically heals %s for %d.",
    HEALEDOTHEROTHER = "%s's %s heals %s for %d.",
    PERIODICAURAHEALOTHERSELF = "You gain %d health from %s's %s.",
    PERIODICAURAHEALSELFSELF = "You gain %d health from %s.",
    PERIODICAURAHEALOTHEROTHER = "%s gains %d health from %s's %s.",
    PERIODICAURAHEALSELFOTHER = "%s gains %d health from your %s.",
    INTERRUPTED = "Interrupted", UNKNOWNOBJECT = "Unknown", CANCEL = "Cancel", OKAY = "Okay",
    ACCEPT = "Accept", DECLINE = "Decline", YES = "Yes", NO = "No",
    ERR_NOT_ENOUGH_MONEY = "You don't have enough money.",
    QUEST_FADING_DISABLE = "0",
}

api.CVARS = {
    cameraDistanceMax = "15", cameraDistanceMaxFactor = "1", autoLootDefault = "0", autoSelfCast = "1",
    nameplateShowEnemies = "0", showTargetOfTarget = "0", lootUnderMouse = "0", Sound_EnableAllSound = "1",
    Sound_MasterVolume = "1", gxResolution = "1024x768", realmName = "Open Vanilla", accountName = "",
    uiScale = "1", useUiScale = "0", profanityFilter = "1", chatBubbles = "1", showLootSpam = "1",
    UnitNameOwn = "0", UnitNamePlayer = "1", UnitNameNPC = "0", statusBarText = "0", showClock = "0",
    cameraYawMoveSpeed = "180", mouseSpeed = "1", screenshotFormat = "jpeg", scriptErrors = "1",
    guildMemberNotify = "0", chatStyle = "classic", removeChatDelay = "0", showTimestamps = "none",
    minimapZoom = "0", minimapInsideZoom = "0",
}

-- --------------------------------------------------------------------------------------------
-- Chat bus: shared by every client that talks to the same "server"
-- --------------------------------------------------------------------------------------------

local Bus = {}
Bus.__index = Bus

-- opts: collapse_spaces (default true), trim (true), max_len (255), raw_pipes = "error"|"allow"
function api.new_bus(opts)
    opts = opts or {}
    local b = setmetatable({
        clients = {}, by_name = {}, queue = {}, log = {},
        now = opts.start or 1000, start = opts.start or 1000, epoch = opts.epoch or 1760000000,
        collapse_spaces = opts.collapse_spaces ~= false, trim = opts.trim ~= false,
        max_len = opts.max_len or 255, raw_pipes = opts.raw_pipes or "error",
        channels = {},   -- lower name -> { name = Name, members = { env = true } }
    }, Bus)
    return b
end
api.bus = api.new_bus()
function api.reset_bus(opts) api.bus = api.new_bus(opts) return api.bus end

function Bus:deliver(env, event, ...)
    table.insert(self.queue, { env = env, event = event, args = { ... }, n = select("#", ...) })
end

-- Run fn on the next pump (a server reply arrives after the request, never inside it).
function Bus:later(fn) table.insert(self.queue, { fn = fn }) end

-- What the server does to a chat line: trim and collapse space runs.
function Bus:serverText(msg)
    if self.collapse_spaces then msg = string.gsub(msg, "  +", " ") end
    if self.trim then msg = string.gsub(string.gsub(msg, "^ +", ""), " +$", "") end
    return msg
end

-- A raw '|' that is not a valid escape gets the line rejected by the 1.12 client.
local function badPipe(msg)
    local i = 1
    while true do
        local a = string.find(msg, "|", i, true)
        if not a then return false end
        local nx = string.sub(msg, a + 1, a + 1)
        if nx == "|" then i = a + 2
        elseif nx == "c" or nx == "r" or nx == "H" or nx == "h" then i = a + 2
        else return true end
    end
end

function Bus:pump(limit)
    limit = limit or 100000
    local n = 0
    while self.queue[1] do
        local q = self.queue
        self.queue = {}
        for _, m in ipairs(q) do
            if m.fn then m.fn() else api.fire(m.env, m.event, unpack(m.args, 1, m.n)) end
            n = n + 1
            if n > limit then error("bus: message storm (more than " .. limit .. " deliveries)") end
        end
    end
    return n
end

function Bus:channelMembers(name)
    local c = self.channels[string.lower(name)]
    return c and c.members or {}
end

-- --------------------------------------------------------------------------------------------
-- Client environment
-- --------------------------------------------------------------------------------------------

local function lib50()
    local s = string
    local str = { byte = s.byte, char = s.char, dump = s.dump, find = s.find, format = s.format,
        gfind = s.gmatch, gsub = s.gsub, len = s.len, lower = s.lower, rep = s.rep, sub = s.sub, upper = s.upper }
    local m = math
    local mth = { abs = m.abs, acos = m.acos, asin = m.asin, atan = m.atan, atan2 = m.atan2, ceil = m.ceil,
        cos = m.cos, deg = m.deg, exp = m.exp, floor = m.floor, frexp = m.frexp, ldexp = m.ldexp, log = m.log,
        log10 = m.log10, max = m.max, min = m.min, mod = m.fmod, pi = m.pi, pow = m.pow, rad = m.rad,
        random = m.random, randomseed = m.randomseed, sin = m.sin, sqrt = m.sqrt, tan = m.tan }
    -- Lua 5.0 table functions: the size is t.n when that field is a number, else the count up
    -- to the first nil (5.1's '#' may stop at any border instead).
    local t = table
    local function getn(tt)
        local n = rawget(tt, "n")
        if type(n) == "number" then return n end
        n = 0
        while rawget(tt, n + 1) ~= nil do n = n + 1 end
        return n
    end
    local function setn(tt, n) if type(rawget(tt, "n")) == "number" then rawset(tt, "n", n) end end
    local tbl = {
        getn = getn, setn = setn,
        insert = function(tt, a, b)
            local n = getn(tt)
            if b == nil then tt[n + 1] = a
            else
                for i = n, a, -1 do tt[i + 1] = tt[i] end
                tt[a] = b
            end
            setn(tt, n + 1)
        end,
        remove = function(tt, pos)
            local n = getn(tt)
            if n == 0 then return nil end
            pos = pos or n
            local v = tt[pos]
            for i = pos, n - 1 do tt[i] = tt[i + 1] end
            tt[n] = nil
            setn(tt, n - 1)
            return v
        end,
        concat = function(tt, sep, i, j) return t.concat(tt, sep or "", i or 1, j or getn(tt)) end,
        sort = function(tt, f)
            local n = getn(tt)
            if rawget(tt, n + 1) ~= nil then        -- 5.1's sort would also see past the 5.0 size
                local part = {}
                for i = 1, n do part[i] = tt[i] end
                t.sort(part, f)
                for i = 1, n do tt[i] = part[i] end
            else
                t.sort(tt, f)
            end
        end,
        foreach = function(tt, f) for k, v in pairs(tt) do local r = f(k, v) if r ~= nil then return r end end end,
        foreachi = function(tt, f) for i = 1, getn(tt) do local r = f(i, tt[i]) if r ~= nil then return r end end end,
    }
    -- the 1.12 'bit' library (32-bit)
    local function u32(x) x = math.floor(x) return x - math.floor(x / 4294967296) * 4294967296 end
    local function bitop(a, b, f)
        a, b = u32(a), u32(b)
        local r, p = 0, 1
        for _ = 1, 32 do
            local x, y = a - math.floor(a / 2) * 2, b - math.floor(b / 2) * 2
            if f(x, y) then r = r + p end
            a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
        end
        return r
    end
    local bit = {
        band = function(a, b) return bitop(a, b, function(x, y) return x == 1 and y == 1 end) end,
        bor = function(a, b) return bitop(a, b, function(x, y) return x == 1 or y == 1 end) end,
        bxor = function(a, b) return bitop(a, b, function(x, y) return x ~= y end) end,
        bnot = function(a) return 4294967295 - u32(a) end,
        lshift = function(a, n) return u32(u32(a) * 2 ^ n) end,
        rshift = function(a, n) return math.floor(u32(a) / 2 ^ n) end,
        arshift = function(a, n) a = u32(a); local r = math.floor(a / 2 ^ n); if a >= 2147483648 then r = r + u32(-(2 ^ (32 - n))) end return u32(r) end,
        mod = function(a, b) return math.fmod(a, b) end,
    }
    return str, mth, tbl, bit
end

local CHAT_EVENTS = {
    "CHAT_MSG_SYSTEM", "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE",
    "CHAT_MSG_PARTY", "CHAT_MSG_RAID", "CHAT_MSG_GUILD", "CHAT_MSG_EMOTE",
}

local function unitFromOpts(o)
    return {
        name = o.name, class = o.class or "WARRIOR", race = o.race or "Human", level = o.level or 60,
        health = o.health or 100, healthMax = o.healthMax or 100, mana = o.mana or 100, manaMax = o.manaMax or 100,
        isPlayer = (o.isPlayer ~= false), hostile = o.hostile, sex = o.sex or 2, faction = o.faction or "Alliance",
        combat = o.combat, debuffs = o.debuffs or {}, buffs = o.buffs or {}, guild = o.guild,
        creature = o.creature, classification = o.classification, dead = o.dead,
    }
end

--[[ api.new_client(opts) -> env
    opts: name, realm, class, race, level, money (copper), guild = { name, rank, members },
          bus (default api.bus), repo (repo root, for art lookups and load helpers),
          art = "repo" (default) | true | false   custom art present?
          bags = { [0] = { size = 16, items = { [slot] = { id, count } } }, ... }
          items = { [id] = { name, quality, icon, sell, stack } }   extra item definitions
          saved = { VarName = value }     SavedVariables restored after each addon loads
          cvars = { name = value }        extra / overridden CVars
          missing = { "UnitCanAssist" }   real API removed (e.g. what the web client lacks)
          party = { { name, class, level }, ... }   NPC party members (no client behind them)
          map = { x, y, zone }
          channels = { "General", "Trade", "LocalDefense" }   stock channels joined at login
          latency = false                 server-side money changes apply at once, not on the next pump
          skills / factions / hk          the skill list, reputations and lifetime honorable kills (see GetSkillLineInfo)
]]
function api.new_client(opts)
    opts = opts or {}
    local bus = opts.bus or api.bus
    local name = opts.name or "Herald"
    assert(not bus.by_name[name], "api.new_client: a client named " .. name .. " is already on this bus")

    local env = {}
    local base = {}
    local env_mt = {
        __index = function(t, k)
            local v = base[k]
            if v ~= nil then return v end
            if type(k) == "string" and not NIL_SET[k] then env.__unknown_reads[k] = true end
            return nil
        end,
    }
    setmetatable(env, env_mt)
    rawset(env, "__base", base)
    rawset(env, "__opts", opts)
    rawset(env, "__bus", bus)
    rawset(env, "__repo", opts.repo or api.repo)
    rawset(env, "__art", opts.art == nil and "repo" or opts.art)
    for _, k in ipairs({ "__errors", "__pcall_errors", "__chat", "__frames", "__regions", "__onupdate",
        "__allevents", "__sounds", "__wnl", "__popups", "__chat_sent", "__addon_sent", "__addon_order",
        "__opened_chat", "__ignores", "__events_fired", "__raid_marks", "__accepted_quests", "__used_items",
        "__loot", "__auctions" }) do
        rawset(env, k, {})
    end
    for _, k in ipairs({ "__evreg", "__unknown_reads", "__unknown_methods", "__missing_art", "__addons",
        "__inventory", "__keys", "__channels", "__server_handlers" }) do
        rawset(env, k, {})
    end
    local saved = deepcopy(opts.saved or {})
    -- Each client is a player who already uses Classic+ (a WenillaCore_Config with a version), so
    -- the first-time setup (WenillaCore/Setup.lua) leaves every addon on, as tests expect.
    -- opts.fresh = true plays a brand-new player instead (the light first-time interface).
    if not opts.fresh then
        saved.WenillaCore_Config = saved.WenillaCore_Config or {}
        if saved.WenillaCore_Config.version == nil then saved.WenillaCore_Config.version = 1 end
    end
    rawset(env, "__saved", saved)
    rawset(env, "__items", shallow(api.ITEMS))
    for id, it in pairs(opts.items or {}) do env.__items[id] = it end
    rawset(env, "__money", opts.money or 123456)
    rawset(env, "__cvars", shallow(api.CVARS))
    for k, v in pairs(opts.cvars or {}) do env.__cvars[k] = v end
    rawset(env, "__map", opts.map or { x = 0.4213, y = 0.6587, zone = "Elwynn Forest" })
    rawset(env, "__guild", opts.guild)

    -- units
    local me = unitFromOpts({ name = name, class = opts.class or "HUNTER", race = opts.race or "Human",
        level = opts.level or 60, guild = opts.guild and opts.guild.name, faction = opts.faction })
    rawset(env, "__units", { player = me })
    if opts.party then
        for i, p in ipairs(opts.party) do env.__units["party" .. i] = unitFromOpts(p) end
    end

    -- bags: backpack 16 slots; bank (-1) 24 slots; everything else absent unless given
    local bags = { [0] = { size = 16, items = {} }, [-1] = { size = 24, items = {} } }
    for bag, b in pairs(opts.bags or {}) do
        bags[bag] = { size = b.size or 16, items = {} }
        for slot, it in pairs(b.items or {}) do
            bags[bag].items[slot] = { id = it.id or it[1], count = it.count or it[2] or 1 }
        end
    end
    rawset(env, "__bags", bags)

    local str, mth, tbl, bit = lib50()
    local B = base
    -- Lua 5.0 base library as the client exposes it
    for _, k in ipairs({ "assert", "collectgarbage", "error", "getfenv", "getmetatable", "ipairs",
        "loadstring", "next", "pairs", "pcall", "rawequal", "rawget", "rawset", "setfenv", "setmetatable",
        "tonumber", "tostring", "type", "unpack", "xpcall" }) do
        B[k] = _G[k]
    end
    B.unpack = function(tt, i, j) return unpack(tt, i or 1, j or tbl.getn(tt)) end
    B.gcinfo = function() return math.floor(collectgarbage("count")), 0 end
    B._VERSION = "Lua 5.0.2"
    B.string, B.math, B.table, B.bit = str, mth, tbl, bit
    -- WoW's global aliases
    B.strbyte, B.strchar, B.strfind, B.strlen, B.strlower, B.strrep, B.strsub, B.strupper =
        str.byte, str.char, str.find, str.len, str.lower, str.rep, str.sub, str.upper
    B.format, B.gsub, B.gfind = str.format, str.gsub, str.gfind
    B.tinsert, B.tremove, B.getn, B.sort, B.foreach, B.foreachi = tbl.insert, tbl.remove, tbl.getn, tbl.sort, tbl.foreach, tbl.foreachi
    B.abs, B.ceil, B.floor, B.max, B.min, B.mod, B.sqrt, B.exp, B.log, B.log10, B.frexp, B.ldexp, B.random, B.randomseed =
        mth.abs, mth.ceil, mth.floor, mth.max, mth.min, mth.mod, mth.sqrt, mth.exp, mth.log, mth.log10, mth.frexp, mth.ldexp, mth.random, mth.randomseed
    -- WoW's global trig works in degrees
    B.sin = function(d) return math.sin(math.rad(d)) end
    B.cos = function(d) return math.cos(math.rad(d)) end
    B.tan = function(d) return math.tan(math.rad(d)) end
    B.asin = function(x) return math.deg(math.asin(x)) end
    B.acos = function(x) return math.deg(math.acos(x)) end
    B.atan = function(x) return math.deg(math.atan(x)) end
    B.atan2 = function(y, x) return math.deg(math.atan2(y, x)) end
    B.deg, B.rad = math.deg, math.rad
    B.getglobal = function(n) return env[n] end
    B.setglobal = function(n, v) env[n] = v end
    B._G = env
    B.debugstack = function() return debug.traceback("", 2) end
    B.debugprofilestart, B.debugprofilestop = NOOP, function() return 0 end
    local errHandler = function(e) api.record_error(env, e, "error handler") end
    B.geterrorhandler = function() return errHandler end
    B.seterrorhandler = function(f) errHandler = f end
    B.message = function(m) table.insert(env.__chat, "[message] " .. tostring(m)) end

    -- pcall that also remembers what it swallowed (the addons hide their own errors this way)
    B.pcall = function(f, ...)
        local res = { n = 0 }
        local function pack(...) res.n = select("#", ...); for i = 1, res.n do res[i] = (select(i, ...)) end end
        pack(pcall(f, ...))
        if not res[1] then table.insert(env.__pcall_errors, api.explain(res[2])) end
        return unpack(res, 1, res.n)
    end

    for k, v in pairs(api.GLOBAL_STRINGS) do B[k] = v end
    B.MERCHANT_ITEMS_PER_PAGE, B.NUM_CHAT_WINDOWS, B.CHAT_TAB_SHOW_DELAY, B.UIERRORS_HOLD_TIME = 10, 7, 0.2, 5
    B.NUM_BAG_SLOTS, B.NUM_BANKBAGSLOTS, B.BANK_CONTAINER, B.MAX_PARTY_MEMBERS, B.MAX_RAID_MEMBERS = 4, 6, -1, 4, 40
    B.RAID_CLASS_COLORS = {
        WARRIOR = { r = 0.78, g = 0.61, b = 0.43 }, MAGE = { r = 0.41, g = 0.8, b = 0.94 }, ROGUE = { r = 1, g = 0.96, b = 0.41 },
        DRUID = { r = 1, g = 0.49, b = 0.04 }, HUNTER = { r = 0.67, g = 0.83, b = 0.45 }, SHAMAN = { r = 0.96, g = 0.55, b = 0.73 },
        PRIEST = { r = 1, g = 1, b = 1 }, WARLOCK = { r = 0.58, g = 0.51, b = 0.79 }, PALADIN = { r = 0.96, g = 0.55, b = 0.73 },
    }

    -- time
    B.GetTime = function() return bus.now end
    B.time = function(t) if t then return os.time(t) end return bus.epoch + math.floor(bus.now - bus.start) end
    B.date = function(fmt, t) return os.date(fmt, t or B.time()) end
    B.GetGameTime = function() return 12, 0 end
    B.GetFramerate = function() return 60 end
    B.GetNetStats = function() return 0, 0, 50 end
    B.GetRealmName = function() return opts.realm or "Open Vanilla" end
    B.GetLocale = function() return "enUS" end
    B.GetBuildInfo = function() return "1.12.1", "5875", "Sep 19 2006" end

    -- input state
    B.IsShiftKeyDown = function() return env.__keys.shift and 1 or nil end
    B.IsControlKeyDown = function() return env.__keys.ctrl and 1 or nil end
    B.IsAltKeyDown = function() return env.__keys.alt and 1 or nil end
    B.GetCursorPosition = function() local c = rawget(env, "__cursor"); if c then return c[1], c[2] end return 512, 384 end

    -- skills, reputation and lifetime PvP: opts.skills = { { name, rank, max } },
    -- opts.factions = { { name, standingId 1..8 } }, opts.hk = lifetime honorable kills
    B.GetNumSkillLines = function() return #(opts.skills or {}) end
    -- opts.skills = { { name, rank, max } or { "Professions", header = true } }
    B.GetSkillLineInfo = function(i)
        local s = (opts.skills or {})[i]
        if s and s.header then return s[1], 1, 1, 0, 0, 0, 0 end
        if s then return s[1], nil, nil, s[2] or 1, 0, 0, s[3] or 300 end
    end
    B.GetNumFactions = function() return #(opts.factions or {}) end
    B.GetFactionInfo = function(i)
        local f = (opts.factions or {})[i]
        if f then return f[1], "", f[2] or 4, 0, 1000, 500, nil, 1, nil, nil end
    end
    B.GetPVPLifetimeStats = function() return opts.hk or 0, 0, 0 end

    -- sound
    B.PlaySound = function(s) table.insert(env.__sounds, s) end
    B.PlaySoundFile = function(s) table.insert(env.__sounds, s) end

    -- CVars (unknown names error like the real client)
    B.GetCVar = function(n)
        local v = env.__cvars[n]
        if v == nil then error("Couldn't find CVar named '" .. tostring(n) .. "' (fake API: add it to api.CVARS if it is a real 1.12 CVar)", 2) end
        return v
    end
    B.SetCVar = function(n, v)
        if env.__cvars[n] == nil then error("Couldn't find CVar named '" .. tostring(n) .. "'", 2) end
        env.__cvars[n] = tostring(v)
    end
    B.RegisterCVar = function(n, v) if env.__cvars[n] == nil then env.__cvars[n] = tostring(v or "") end end
    B.RegisterForSave = NOOP

    -- units
    B.UnitName = function(u) local x = api.unit(env, u); if x then return x.name end end
    B.UnitClass = function(u) local x = api.unit(env, u); if x then return api.CLASS_NAMES[x.class] or x.class, x.class end end
    B.UnitRace = function(u) local x = api.unit(env, u); if x then return x.race, api.RACE_FILES[x.race] or x.race end end
    B.UnitLevel = function(u) local x = api.unit(env, u); if x then return x.level end return 0 end
    B.UnitExists = function(u) return api.unit(env, u) and 1 or nil end
    B.UnitIsPlayer = function(u) local x = api.unit(env, u); return x and x.isPlayer and 1 or nil end
    B.UnitPlayerControlled = B.UnitIsPlayer
    B.UnitHealth = function(u) local x = api.unit(env, u); return x and x.health or 0 end
    B.UnitHealthMax = function(u) local x = api.unit(env, u); return x and x.healthMax or 0 end
    B.UnitMana = function(u) local x = api.unit(env, u); return x and x.mana or 0 end
    B.UnitManaMax = function(u) local x = api.unit(env, u); return x and x.manaMax or 0 end
    B.UnitPowerType = function() return 0 end
    B.UnitSex = function(u) local x = api.unit(env, u); return x and x.sex or 1 end
    B.UnitFactionGroup = function(u) local x = api.unit(env, u); if x then return x.faction, x.faction end end
    B.UnitAffectingCombat = function(u) local x = api.unit(env, u); return x and x.combat and 1 or nil end
    B.UnitIsDead = function(u) local x = api.unit(env, u); return x and x.dead and 1 or nil end
    B.UnitIsGhost = function(u) local x = api.unit(env, u); return x and x.ghost and 1 or nil end
    B.UnitIsDeadOrGhost = function(u) local x = api.unit(env, u); return x and (x.dead or x.ghost) and 1 or nil end
    B.UnitIsConnected = function(u) return api.unit(env, u) and 1 or nil end
    B.UnitIsUnit = function(a, b) local x, y = api.unit(env, a), api.unit(env, b); return x and y and x.name == y.name and 1 or nil end
    B.UnitCanAttack = function(a, b)
        local x, y = api.unit(env, a), api.unit(env, b)
        return x and y and ((x.hostile and 1 or 0) ~= (y.hostile and 1 or 0)) and 1 or nil
    end
    B.UnitIsEnemy = B.UnitCanAttack
    B.UnitIsFriend = function(a, b)
        local x, y = api.unit(env, a), api.unit(env, b)
        return x and y and ((x.hostile and 1 or 0) == (y.hostile and 1 or 0)) and 1 or nil
    end
    B.UnitReaction = function(a, b) if B.UnitCanAttack(a, b) then return 2 end return 5 end
    B.UnitCanAssist = function(a, b) if B.UnitExists(a) and B.UnitExists(b) and B.UnitIsFriend(a, b) then return 1 end end
    B.UnitIsTrivial = function() return nil end
    B.UnitClassification = function(u) local x = api.unit(env, u); return x and (x.classification or "normal") end
    B.UnitCreatureType = function(u) local x = api.unit(env, u); return x and (x.creature or (x.isPlayer and "Humanoid") or "Beast") end
    B.UnitDebuff = function(u, i)
        local x = api.unit(env, u); local d = x and x.debuffs[i]
        if d then return d.texture or d[1], d.stacks or d[2] or 1, d.type or d[3] end
    end
    B.UnitBuff = function(u, i)
        local x = api.unit(env, u); local d = x and x.buffs[i]
        if d then return d.texture or d[1], d.stacks or d[2] or 1 end
    end
    B.UnitInParty = function(u) return api.unit(env, u) and 1 or nil end
    B.UnitInRaid = function(u) return nil end
    B.UnitIsPartyLeader = function(u) return u == "player" and 1 or nil end
    B.UnitOnTaxi = function() return nil end
    B.SetPortraitTexture = NOOP
    B.TargetUnit = function(u) api.set_target(env, u) end
    B.ClearTarget = function() api.set_target(env, nil) end
    B.GetComboPoints = function() return 0 end

    -- group
    B.GetNumPartyMembers = function()
        local n = 0
        for i = 1, 4 do if env.__units["party" .. i] then n = i end end
        return n
    end
    B.GetNumRaidMembers = function()
        local n = 0
        for i = 1, 40 do if env.__units["raid" .. i] then n = i end end
        return n
    end
    B.GetRaidRosterInfo = function(i)
        local x = env.__units["raid" .. i]
        if x then return x.name, (i == 1) and 2 or 0, math.floor((i - 1) / 5) + 1, x.level, api.CLASS_NAMES[x.class], x.class, "Molten Core", 1, nil end
    end
    B.IsPartyLeader = function() return 1 end
    B.IsRaidLeader = function() return 1 end
    B.IsRaidOfficer = function() return 1 end
    B.SetRaidTarget = function(u, i) table.insert(env.__raid_marks, { u, i }) end
    B.GetRaidTargetIndex = function() return nil end
    B.DoReadyCheck = NOOP

    -- guild & ignore list
    B.IsInGuild = function() return env.__guild and 1 or nil end
    B.GetGuildInfo = function(u)
        if u == "player" and env.__guild then return env.__guild.name, env.__guild.rank or "Officer", env.__guild.rankIndex or 1 end
    end
    B.GetNumGuildMembers = function() return env.__guild and (env.__guild.members or 1) or 0, env.__guild and (env.__guild.online or 1) or 0 end
    B.GuildRoster = NOOP
    B.GetNumIgnores = function() return #env.__ignores end
    B.GetIgnoreName = function(i) return env.__ignores[i] end
    B.AddIgnore = function(n) table.insert(env.__ignores, n) end

    -- money, bags, items
    B.GetMoney = function() return env.__money end
    B.GetContainerNumSlots = function(bag) local b = env.__bags[bag]; return b and b.size or 0 end
    B.GetContainerItemInfo = function(bag, slot)
        local it = api.bag_slot(env, bag, slot)
        if not it then return nil end
        local d = api.item(env, it.id) or {}
        return d.icon or "Interface\\Icons\\INV_Misc_QuestionMark", it.count or 1, it.locked and 1 or nil, d.quality or 1, nil
    end
    B.GetContainerItemLink = function(bag, slot)
        local it = api.bag_slot(env, bag, slot)
        return it and api.item_link(env, it.id)
    end
    -- What the server changes (money, repairs) reaches the client one round trip later, like the
    -- real coinage update; opts.latency = false applies it at once.
    local function fromServer(fn) if opts.latency == false then fn() else bus:later(fn) end end
    rawset(env, "__from_server", fromServer)
    B.UseContainerItem = function(bag, slot)
        local it = api.bag_slot(env, bag, slot)
        if not it then return end
        table.insert(env.__used_items, { bag, slot, it.id })
        if env.__merchant then           -- selling
            local d = api.item(env, it.id) or {}
            env.__bags[bag].items[slot] = nil
            fromServer(function()
                env.__money = env.__money + (d.sell or 0) * (it.count or 1)
                api.fire(env, "BAG_UPDATE", bag)
                api.fire(env, "PLAYER_MONEY")
            end)
        end
    end
    B.PickupContainerItem = function(bag, slot) env.__cursor = { bag, slot } end
    B.SplitContainerItem = NOOP
    B.CursorHasItem = function() return env.__cursor and 1 or nil end
    B.ClearCursor = function() env.__cursor = nil end
    B.GetInventoryItemLink = function(u, slot) local id = env.__inventory[slot]; return id and api.item_link(env, id) end
    B.GetInventoryItemTexture = function(u, slot) local d = api.item(env, env.__inventory[slot]); return d and d.icon end
    B.GetInventorySlotInfo = function(n) return 1, "Interface\\PaperDoll\\UI-PaperDoll-Slot-Head" end
    B.BankButtonIDToInvSlotID = function(id) return 39 + id end
    B.GetItemInfo = function(x)
        local id = type(x) == "number" and x or tonumber(string.match(tostring(x), "item:(%d+)"))
        local d = id and api.item(env, id)
        if d then return d.name, "item:" .. id .. ":0:0:0", d.quality or 1, d.minLevel or 1, d.type or "Miscellaneous", d.subType or "", d.stack or 1, d.equip or "", d.icon end
    end
    local QUALITY_RGB = { [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 },
        [3] = { 0, 0.44, 0.87 }, [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 }, [6] = { 0.9, 0.8, 0.5 } }
    -- SetPortraitToTexture(texture or its global name, path): the texture shows the image cut to a circle
    B.SetPortraitToTexture = function(t, path)
        if type(t) == "string" then t = rawget(env, t) end
        if not t or not ST[t] then error("SetPortraitToTexture: no such texture", 2) end
        M.SetTexture(t, path)
        ST[t].circular = true
    end
    B.GetItemQualityColor = function(q)
        local c = QUALITY_RGB[q] or QUALITY_RGB[1]
        return c[1], c[2], c[3], "|" .. "c" .. (api.QUALITY_HEX[q] or "ffffffff")
    end

    -- merchant
    B.GetMerchantNumItems = function() return env.__merchant and #env.__merchant.items or 0 end
    B.GetMerchantItemLink = function(i) local m = env.__merchant; local it = m and m.items[i]; return it and api.item_link(env, it.id) end
    B.GetMerchantItemInfo = function(i)
        local m = env.__merchant; local it = m and m.items[i]
        if not it then return nil end
        local d = api.item(env, it.id) or {}
        return d.name, d.icon, it.price or 0, it.quantity or 1, it.available or -1, 1
    end
    B.BuyMerchantItem = function(i, n)
        local m = env.__merchant; local it = m and m.items[i]
        if it then fromServer(function() env.__money = env.__money - (it.price or 0) * (n or 1); api.fire(env, "PLAYER_MONEY") end) end
    end
    B.CanMerchantRepair = function() return env.__merchant and env.__merchant.repair and 1 or nil end
    B.GetRepairAllCost = function()
        local m = env.__merchant
        local c = m and m.repairCost or 0
        return c, (c > 0) and 1 or nil
    end
    B.RepairAllItems = function()
        local m = env.__merchant
        if m and (m.repairCost or 0) > 0 then
            local cost = m.repairCost
            fromServer(function()
                env.__money = env.__money - cost
                m.repairCost = 0
                api.fire(env, "PLAYER_MONEY")
            end)
        end
    end
    B.GetNumBuybackItems = function() return 0 end

    -- auction house
    B.GetNumAuctionItems = function(kind) return #env.__auctions, #env.__auctions end
    B.GetAuctionItemInfo = function(kind, i)
        local a = env.__auctions[i]
        if not a then return nil end
        local d = api.item(env, a.id) or {}
        return d.name, d.icon, a.count or 1, d.quality or 1, 1, 1, a.minBid or 1, 1, a.buyout or 0, 0, nil, a.owner
    end
    B.GetAuctionItemLink = function(kind, i) local a = env.__auctions[i]; return a and api.item_link(env, a.id) end

    -- loot
    B.GetNumLootItems = function() return #env.__loot end
    B.GetLootSlotInfo = function(i) local l = env.__loot[i]; local d = l and api.item(env, l.id); if d then return d.icon, d.name, l.count or 1, d.quality end end
    B.GetLootSlotLink = function(i) local l = env.__loot[i]; return l and api.item_link(env, l.id) end
    -- other item-link sources the tooltip hooks read (nothing behind them in the sim)
    for _, n in ipairs({ "GetQuestItemLink", "GetQuestLogItemLink", "GetTradePlayerItemLink", "GetTradeTargetItemLink",
        "GetCraftItemLink", "GetCraftReagentItemLink", "GetTradeSkillItemLink", "GetTradeSkillReagentItemLink" }) do
        B[n] = function() return nil end
    end

    -- quests & map
    B.AcceptQuest = function() table.insert(env.__accepted_quests, B.GetTime()) end
    B.DeclineQuest = NOOP
    B.GetPlayerMapPosition = function(u) if u == "player" then return env.__map.x or 0, env.__map.y or 0 end return 0, 0 end
    B.SetMapToCurrentZone = NOOP
    B.GetRealZoneText = function() return env.__map.zone or "" end
    B.GetZoneText = B.GetRealZoneText
    B.GetMinimapZoneText = B.GetRealZoneText
    B.GetSubZoneText = function() return "" end
    B.GetCurrentMapZone = function() return 1 end

    -- addons
    B.GetNumAddOns = function() return #env.__addon_order end
    B.GetAddOnInfo = function(i)
        local n = type(i) == "number" and env.__addon_order[i] or i
        local a = n and env.__addons[n]
        if a then return n, a.meta.Title or n, a.meta.Notes or "", 1, 1, nil, nil end
    end
    B.IsAddOnLoaded = function(n) return env.__addons[n] and 1 or nil end
    B.GetAddOnMetadata = function(n, field) local a = env.__addons[n]; return a and a.meta[field] end
    B.EnableAddOn, B.DisableAddOn = NOOP, NOOP
    B.ReloadUI = function() env.__reload_requested = true end

    -- chat
    B.SendChatMessage = function(msg, kind, lang, target)
        if type(msg) ~= "string" then error("Usage: SendChatMessage(\"text\" [, \"type\" [, \"language\" [, \"channel\"]]])", 2) end
        kind = string.upper(kind or "SAY")
        table.insert(env.__chat_sent, { msg = msg, kind = kind, target = target })
        if string.len(msg) > bus.max_len then
            api.record_error(env, "SendChatMessage: line of " .. string.len(msg) .. " bytes (the 1.12 limit is 255)")
            msg = string.sub(msg, 1, bus.max_len)
        end
        if bus.raw_pipes == "error" and badPipe(msg) then
            api.record_error(env, "SendChatMessage: raw '|' in a chat line (the 1.12 client refuses it): " .. msg)
            return
        end
        api.__route_chat(env, msg, kind, target)
    end
    B.SendAddonMessage = function(prefix, msg, kind)
        kind = string.upper(kind or "")
        table.insert(env.__addon_sent, { prefix = prefix, msg = msg, kind = kind })
        if string.len(prefix or "") + string.len(msg or "") > 254 then
            api.record_error(env, "SendAddonMessage: prefix + message longer than 254 bytes")
        end
        if string.find(prefix or "", "\t", 1, true) then api.record_error(env, "SendAddonMessage: tab in prefix") end
        if kind ~= "PARTY" and kind ~= "RAID" and kind ~= "GUILD" and kind ~= "BATTLEGROUND" then
            api.record_error(env, "SendAddonMessage: '" .. kind .. "' is not a 1.12 addon channel (PARTY, RAID, GUILD, BATTLEGROUND)")
            return
        end
        for _, e in ipairs(api.group_members(env, kind)) do
            bus:deliver(e, "CHAT_MSG_ADDON", prefix, msg, kind, name)
        end
    end
    B.JoinChannelByName = function(ch)
        local low = string.lower(ch)
        if env.__channels[low] then return end
        local id = 1
        local used = {}
        for _, c in pairs(env.__channels) do used[c.id] = true end
        while used[id] do id = id + 1 end
        env.__channels[low] = { id = id, name = ch }
        local c = bus.channels[low]
        if not c then c = { name = ch, members = {} } bus.channels[low] = c end
        c.members[env] = true
        bus:deliver(env, "CHAT_MSG_CHANNEL_NOTICE", "YOU_JOINED", "", "", id .. ". " .. ch, "", "", 0, id, ch)
        return id
    end
    B.LeaveChannelByName = function(ch)
        local low = string.lower(ch)
        local c = env.__channels[low]
        if not c then return end
        env.__channels[low] = nil
        if bus.channels[low] then bus.channels[low].members[env] = nil end
        bus:deliver(env, "CHAT_MSG_CHANNEL_NOTICE", "YOU_LEFT", "", "", c.id .. ". " .. c.name, "", "", 0, c.id, c.name)
    end
    B.GetChannelName = function(x)
        if type(x) == "number" then
            for _, c in pairs(env.__channels) do if c.id == x then return c.id, c.name end end
            return 0, nil
        end
        local c = env.__channels[string.lower(tostring(x or ""))]
        if c then return c.id, c.name end
        return 0, nil
    end
    B.GetChannelList = function()
        local out = {}
        for _, c in pairs(env.__channels) do table.insert(out, c.id); table.insert(out, c.name) end
        return unpack(out)
    end
    B.ChatFrame_OnEvent = function(ev)
        local f = env.this or env.ChatFrame1
        local a1, a2, a4 = env.arg1, env.arg2, env.arg4
        local line
        if ev == "CHAT_MSG_SYSTEM" then line = tostring(a1)
        elseif ev == "CHAT_MSG_SAY" then line = "[" .. tostring(a2) .. "] says: " .. tostring(a1)
        elseif ev == "CHAT_MSG_YELL" then line = "[" .. tostring(a2) .. "] yells: " .. tostring(a1)
        elseif ev == "CHAT_MSG_WHISPER" then line = "[" .. tostring(a2) .. "] whispers: " .. tostring(a1)
        elseif ev == "CHAT_MSG_WHISPER_INFORM" then line = "To [" .. tostring(a2) .. "]: " .. tostring(a1)
        elseif ev == "CHAT_MSG_CHANNEL" then line = "[" .. tostring(a4) .. "] [" .. tostring(a2) .. "]: " .. tostring(a1)
        elseif ev == "CHAT_MSG_CHANNEL_NOTICE" then line = "Channel notice " .. tostring(a1) .. ": [" .. tostring(a4) .. "]"
        elseif ev == "CHAT_MSG_GUILD" then line = "[Guild] [" .. tostring(a2) .. "]: " .. tostring(a1)
        elseif ev == "CHAT_MSG_OFFICER" then line = "[Officer] [" .. tostring(a2) .. "]: " .. tostring(a1)
        elseif ev == "CHAT_MSG_PARTY" then line = "[Party] [" .. tostring(a2) .. "]: " .. tostring(a1)
        elseif ev == "CHAT_MSG_RAID" then line = "[Raid] [" .. tostring(a2) .. "]: " .. tostring(a1)
        else line = "[" .. ev .. "] " .. (a2 and ("[" .. tostring(a2) .. "]: ") or "") .. tostring(a1) end
        if f and f.AddMessage then f:AddMessage(line) end
    end
    B.ChatFrame_RemoveChannel = NOOP
    B.ChatFrame_AddChannel = NOOP
    B.ChatFrame_OpenChat = function(text) table.insert(env.__opened_chat, text) end
    B.ChatFrame_AddMessageGroup = NOOP
    B.ChatFrame_RemoveMessageGroup = NOOP

    -- FrameXML odds and ends
    B.HideUIPanel = function(f) if f then f:Hide() end end
    B.ShowUIPanel = function(f) if f then f:Show() end end
    B.ToggleWorldMap = function() local w = env.WorldMapFrame; if w:IsShown() then w:Hide() else w:Show() end end
    B.ScrollingEdit_OnCursorChanged = NOOP
    B.ScrollingEdit_OnUpdate = NOOP
    B.ScrollingEdit_OnTextChanged = NOOP
    B.UnitPopup_OnClick = function() env.__unitpopup_clicked = env.this and env.this.value end
    B.UnitPopup_ShowMenu = NOOP
    B.ToggleDropDownMenu = NOOP
    B.UIDropDownMenu_Initialize = NOOP
    B.UIDropDownMenu_AddButton = NOOP
    B.CloseDropDownMenus = NOOP
    B.GameTooltip_SetDefaultAnchor = function(t, owner) t:SetOwner(owner, "ANCHOR_NONE") end
    B.SecondsToTime = function(s) return math.floor(s) .. " sec" end
    B.tDeleteItem = function(t, v) for i = #t, 1, -1 do if t[i] == v then table.remove(t, i) end end end
    B.updateContainerFrameAnchors = NOOP
    -- the stock bag functions the Vault hooks
    for _, n in ipairs({ "OpenAllBags", "ToggleBackpack", "OpenBackpack", "ToggleBag", "CloseAllBags", "CloseBackpack", "OpenBag", "CloseBag" }) do
        local fn = n
        B[n] = function() env.__stock_bags = fn end
    end
    B.MerchantFrame_UpdateMerchantInfo = function() api.__stock_merchant_update(env) end
    B.MerchantFrame_UpdateBuybackInfo = NOOP
    B.StaticPopup_Show = function(which, a1, a2, data)
        local d = env.StaticPopupDialogs[which]
        if not d then return nil end
        local text = d.text and string.format(d.text, a1 or "", a2 or "") or ""
        local p = env.StaticPopup1
        p.which, p.data = which, data
        M.SetText(env.StaticPopup1Text, text)
        table.insert(env.__popups, { which = which, text = text, data = data })
        p:Show()
        if d.OnShow then local save = env.this; env.this = p; d.OnShow(data); env.this = save end
        return p
    end
    B.StaticPopup_Hide = function(which) local p = env.StaticPopup1; if p.which == which then p:Hide(); p.which = nil end end
    B.StaticPopup_Visible = function(which) local p = env.StaticPopup1; if p.which == which and p:IsShown() then return "StaticPopup1" end end
    B.CreateFont = function(n) local f = newObject(env, "Font", n, nil, true) return f end

    -- more of the client, from devkit/sim/ext/*.lua (mail, loot, talents, equipment, ...)
    for _, ext in ipairs(api.client_extensions) do ext(env, B, opts) end

    -- intentionally nil (does not exist in 1.12)
    for _, n in ipairs(api.NIL_GLOBALS) do B[n] = nil end
    for _, n in ipairs(opts.missing or {}) do B[n] = nil end

    -- widgets
    B.CreateFrame = function(ftype, fname, parent, template)
        if not FRAME_TYPES[ftype] then error("CreateFrame: Unknown frame type '" .. tostring(ftype) .. "'", 2) end
        if template and not TEMPLATES[template] then
            error("CreateFrame: template '" .. tostring(template) .. "' is not modelled by the sim (add it to TEMPLATES in wow_api.lua)", 2)
        end
        local f = newObject(env, ftype, fname, parent)
        ST[f].template = template                 -- what the client would draw it with (render/)
        local kind = template and TEMPLATES[template]
        if kind == "check" and fname then newObject(env, "FontString", fname .. "Text", f, true) end
        if kind == "scroll" and fname then newObject(env, "Slider", fname .. "ScrollBar", f) end
        if kind == "tooltip" then ST[f].isTooltip = true end
        return f
    end

    -- set up the stock UI objects addons expect to find
    local function F(t, n, p) return newObject(env, t, n, p) end
    local UIParent = F("Frame", "UIParent")
    ST[UIParent].w, ST[UIParent].h = 1024, 768
    F("Frame", "WorldFrame")
    local mm = F("Minimap", "Minimap", UIParent); ST[mm].w, ST[mm].h, ST[mm].left, ST[mm].top = 140, 140, 870, 750
    F("Frame", "MinimapCluster", UIParent)
    local tf = F("Button", "TargetFrame", UIParent); ST[tf].shown = false
    newObject(env, "Texture", "TargetPortrait", tf, true)
    F("Button", "PlayerFrame", UIParent)
    local tip = F("GameTooltip", "GameTooltip", UIParent); ST[tip].shown = false; ST[tip].strata = "TOOLTIP"
    local ref = F("GameTooltip", "ItemRefTooltip", UIParent); ST[ref].shown = false
    for i = 1, 7 do
        local cf = F("ScrollingMessageFrame", "ChatFrame" .. i, UIParent)
        local tab = F("Button", "ChatFrame" .. i .. "Tab", UIParent)
        ST[tab].w, ST[tab].left = 64, 20 + (i - 1) * 70
        if i > 2 then ST[cf].shown = false; ST[tab].shown = false end
        if i == 1 then
            ST[cf].w, ST[cf].h = 430, 120          -- the stock default chat frame's size and place
            M.SetPoint(cf, "BOTTOMLEFT", UIParent, "BOTTOMLEFT", 32, 95)
            ST[cf].isChat = true
            for _, ev in ipairs(CHAT_EVENTS) do M.RegisterEvent(cf, ev) end
            M.SetScript(cf, "OnEvent", function() local f = env.ChatFrame_OnEvent; if f then f(env.event) end end)
        end
    end
    B.DEFAULT_CHAT_FRAME = env.ChatFrame1
    B.SELECTED_CHAT_FRAME = env.ChatFrame1
    local eb = F("EditBox", "ChatFrameEditBox", UIParent); ST[eb].shown = false
    F("MessageFrame", "UIErrorsFrame", UIParent)
    local wm = F("Frame", "WorldMapFrame", UIParent); ST[wm].shown = false
    -- the stock action bar's right end: the eight micro buttons (MainMenuBar.xml anchors them to
    -- the art frame at x 546, each the last one's BOTTOMRIGHT -3), the key ring and the bags
    local mmb = F("Frame", "MainMenuBar", UIParent); ST[mmb].w, ST[mmb].h = 1024, 53
    table.insert(ST[mmb].points, { "BOTTOM", UIParent, "BOTTOM", 0, 0 })
    local art = F("Frame", "MainMenuBarArtFrame", mmb); ST[art].w, ST[art].h = 1024, 53
    table.insert(ST[art].points, { "BOTTOMLEFT", mmb, "BOTTOMLEFT", 0, 0 })
    local prev
    for _, n in ipairs({ "Character", "Spellbook", "Talent", "QuestLog", "Socials", "WorldMap", "MainMenu", "Help" }) do
        local b = rawget(env, n .. "MicroButton") or F("Button", n .. "MicroButton", art)
        ST[b].w, ST[b].h = 28, 58
        ST[b].points = {}
        if prev then table.insert(ST[b].points, { "BOTTOMLEFT", prev, "BOTTOMRIGHT", -3, 0 })
        else table.insert(ST[b].points, { "BOTTOMLEFT", art, "BOTTOMLEFT", 546, 2 }) end
        ST[b].stock = n
        -- the stock OnClick (MainMenuBarMicroButtons.xml), resolved at click time
        local ON = { Character = function() env.ToggleCharacter("PaperDollFrame") end,
            Spellbook = function() env.ToggleSpellBook(env.BOOKTYPE_SPELL) end, Talent = function() env.ToggleTalentFrame() end,
            QuestLog = function() env.ToggleQuestLog() end, Socials = function() env.ToggleFriendsFrame() end,
            WorldMap = function() env.ToggleWorldMap() end, Help = function() env.ToggleHelpFrame() end,
            MainMenu = function() local g = env.GameMenuFrame; if g:IsShown() then g:Hide() else g:Show() end end }
        if not ST[b].scripts.OnClick then M.SetScript(b, "OnClick", ON[n]) end
        prev = b
    end
    -- 1.12's UpdateMicroButtons (MainMenuBarMicroButtons.lua): the Talents button shows from level 10
    -- and the Quest Log button is hung on it again
    if rawget(B, "UpdateMicroButtons") == nil then
        B.UpdateMicroButtons = function()
            local t, q = env.TalentMicroButton, env.QuestLogMicroButton
            if (env.UnitLevel("player") or 1) < 10 then
                M.Hide(t); M.SetPoint(q, "BOTTOMLEFT", t, "BOTTOMLEFT", 0, 0)
            else
                M.Show(t); M.SetPoint(q, "BOTTOMLEFT", t, "BOTTOMRIGHT", -3, 0)
            end
        end
    end
    local bp = F("Button", "MainMenuBarBackpackButton", art); ST[bp].w, ST[bp].h = 37, 37
    table.insert(ST[bp].points, { "BOTTOMRIGHT", art, "BOTTOMRIGHT", -6, 2 })
    prev = bp
    for i = 0, 3 do
        local b = F("Button", "CharacterBag" .. i .. "Slot", art); ST[b].w, ST[b].h = 37, 37
        table.insert(ST[b].points, { "RIGHT", prev, "LEFT", -5, 0 })
        prev = b
    end
    local kr = F("Button", "KeyRingButton", art); ST[kr].w, ST[kr].h = 18, 39
    table.insert(ST[kr].points, { "RIGHT", prev, "LEFT", -1, 0 })
    -- what the stock toggles open, in call order (tests read env.__toggles)
    env.__toggles = {}
    for _, n in ipairs({ "ToggleCharacter", "ToggleSpellBook", "ToggleTalentFrame", "ToggleQuestLog",
        "ToggleFriendsFrame", "ToggleGameMenu", "ToggleHelpFrame" }) do
        local name = n
        if rawget(B, name) == nil then
            B[name] = function(a1) table.insert(env.__toggles, name .. (a1 and (" " .. tostring(a1)) or "")) end
        end
    end
    local function gap(name, fn) if rawget(B, name) == nil then B[name] = fn end end
    gap("BOOKTYPE_SPELL", "spell")
    gap("BOOKTYPE_PET", "pet")
    -- spellbook: opts.spells = { "Find Herbs", ... } or { { name, rank, texture }, ... }
    local function spellAt(i)
        local sp = (opts.spells or {})[i]
        if type(sp) == "string" then return { sp } end
        return sp
    end
    gap("GetSpellName", function(i, book) local sp = spellAt(i); if sp then return sp[1], sp[2] or "" end end)
    gap("GetSpellTexture", function(i) local sp = spellAt(i); return sp and (sp[3] or "Interface\\Icons\\INV_Misc_QuestionMark") end)
    gap("GetNumSpellTabs", function() return 1 end)
    gap("GetSpellTabInfo", function(i) if i == 1 then return "General", "", 0, table.getn(opts.spells or {}) end end)
    env.__casts = env.__casts or {}
    gap("CastSpellByName", function(n) table.insert(env.__casts, n) end)
    gap("CastSpell", function(i, book) local sp = spellAt(i); table.insert(env.__casts, sp and sp[1] or i) end)
    -- key bindings, where no extension models them: env.__bindings[key] = action
    env.__bindings = env.__bindings or {}
    for k, v in pairs(opts.bindings or {}) do env.__bindings[k] = v end
    gap("GetBindingAction", function(key) return env.__bindings[key] or "" end)
    gap("GetBindingKey", function(action) for k, v in pairs(env.__bindings) do if v == action then return k end end end)
    gap("SetBinding", function(key, action) env.__bindings[key] = action; return 1 end)
    gap("SaveBindings", function() end)
    gap("GetCurrentBindingSet", function() return 1 end)
    local gm = F("Frame", "GameMenuFrame", UIParent); ST[gm].shown = false; ST[gm].h = 250
    F("Button", "GameMenuButtonMacros", gm)
    F("Button", "GameMenuButtonLogout", gm)
    local uo = F("Frame", "UIOptionsFrame", UIParent); ST[uo].shown = false
    F("Button", "UIOptionsFrameDefaults", uo)
    local bank = F("Frame", "BankFrame", UIParent); ST[bank].shown = false
    local sp = F("Frame", "StaticPopup1", UIParent); ST[sp].shown = false
    newObject(env, "FontString", "StaticPopup1Text", sp, true)
    local mf = F("Frame", "MerchantFrame", UIParent); ST[mf].shown = false
    rawset(mf, "page", 1); rawset(mf, "selectedTab", 1)
    for i = 1, 12 do
        local item = F("Frame", "MerchantItem" .. i, mf)
        newObject(env, "FontString", "MerchantItem" .. i .. "Name", item, true)
        F("Frame", "MerchantItem" .. i .. "MoneyFrame", item)
        local ib = F("Button", "MerchantItem" .. i .. "ItemButton", item)
        newObject(env, "Texture", "MerchantItem" .. i .. "ItemButtonIconTexture", ib, true)
    end
    for _, fo in ipairs({ "GameFontNormal", "GameFontNormalSmall", "GameFontNormalLarge", "GameFontHighlight",
        "GameFontHighlightSmall", "GameFontHighlightLarge", "GameFontDisable", "GameFontDisableSmall",
        "GameFontGreen", "GameFontRed", "GameFontWhite", "NumberFontNormal", "NumberFontNormalSmall",
        "ChatFontNormal", "SystemFont", "GameFontBlack" }) do
        B[fo] = newObject(env, "Font", nil, nil, true)
    end
    B.UISpecialFrames = {}
    B.SlashCmdList = {}
    B.StaticPopupDialogs = {}
    B.UnitPopupButtons = { WHISPER = { text = "Whisper" }, CANCEL = { text = "Cancel" } }
    B.UnitPopupMenus = {
        PLAYER = { "WHISPER", "INSPECT", "INVITE", "TARGET", "CANCEL" }, PARTY = { "WHISPER", "INSPECT", "CANCEL" },
        RAID = { "WHISPER", "INSPECT", "CANCEL" }, FRIEND = { "WHISPER", "INVITE", "TARGET", "CANCEL" },
        SELF = { "RAID_TARGET_ICON", "CANCEL" },
    }
    B.UIDROPDOWNMENU_INIT_MENU = nil

    -- move every base value that is a widget into base too (they were rawset on env by name)
    for _, k in ipairs({ "UIParent", "WorldFrame", "Minimap", "MinimapCluster", "TargetFrame", "TargetPortrait",
        "PlayerFrame", "GameTooltip", "ItemRefTooltip", "ChatFrameEditBox", "UIErrorsFrame", "WorldMapFrame",
        "GameMenuFrame", "GameMenuButtonMacros", "GameMenuButtonLogout", "UIOptionsFrame", "UIOptionsFrameDefaults",
        "BankFrame", "StaticPopup1", "StaticPopup1Text", "MerchantFrame" }) do
        B[k] = rawget(env, k)
    end

    -- extensions that need the stock UI above (devkit/sim/ext/*.lua: api.client_late_extensions)
    for _, ext in ipairs(api.client_late_extensions or {}) do ext(env, B, opts) end

    -- the stock channels the client joins at login take the low numbers
    for i, ch in ipairs(opts.channels or { "General", "Trade", "LocalDefense" }) do
        env.__channels[string.lower(ch)] = { id = i, name = ch }
        local c = bus.channels[string.lower(ch)]
        if not c then c = { name = ch, members = {} } bus.channels[string.lower(ch)] = c end
        c.members[env] = true
    end

    -- harness conveniences on the env itself
    rawset(env, "__slash", function(text) return api.slash(env, text) end)
    rawset(env, "__name", name)

    table.insert(bus.clients, env)
    bus.by_name[name] = env
    return env
end

-- --------------------------------------------------------------------------------------------
-- Units, items, bags
-- --------------------------------------------------------------------------------------------

function api.unit(env, u)
    if type(u) ~= "string" then return nil end
    return env.__units[string.lower(u)]
end

-- def: nil (clear) | "Name" (a client on the bus, else a hostile NPC) | table (see unitFromOpts)
local function resolveUnit(env, def)
    if def == nil then return nil end
    if type(def) == "string" then
        local other = env.__bus.by_name[def]
        if other then return shallow(other.__units.player) end
        if env.__units.player.name == def then return env.__units.player end
        return unitFromOpts({ name = def, isPlayer = false, hostile = true, level = 60 })
    end
    if def.name and env.__units.player.name == def.name and not def.isPlayer then return env.__units.player end
    return unitFromOpts(def)
end
api.resolve_unit = resolveUnit

function api.set_unit(env, token, def) env.__units[token] = resolveUnit(env, def) end

-- Target someone (or nil); fires PLAYER_TARGET_CHANGED.
function api.set_target(env, def)
    env.__units.target = resolveUnit(env, def)
    if env.__units.target then env.TargetFrame:Show() else env.TargetFrame:Hide() end
    api.fire(env, "PLAYER_TARGET_CHANGED")
end

-- Mouse over a unit in the world: the stock tooltip shows it, then UPDATE_MOUSEOVER_UNIT fires.
function api.mouseover(env, def)
    env.__units.mouseover = resolveUnit(env, def)
    local tip = env.GameTooltip
    if env.__units.mouseover then
        env.GameTooltip_SetDefaultAnchor(tip, env.UIParent)
        tip:SetUnit("mouseover")
        tip:Show()
    else
        tip:Hide()
    end
    api.fire(env, "UPDATE_MOUSEOVER_UNIT")
end

function api.item(env, id) return id and env.__items[tonumber(id)] end
function api.add_item(env, id, def) env.__items[id] = def end
function api.item_link(env, id)
    local d = api.item(env, id)
    if not d then return nil end
    return "|c" .. (api.QUALITY_HEX[d.quality or 1]) .. "|Hitem:" .. id .. ":0:0:0|h[" .. d.name .. "]|h|r"
end
function api.bag_slot(env, bag, slot)
    local b = env.__bags[bag]
    return b and b.items[slot]
end
-- Put an item in a bag slot (first free backpack slot by default). Fires BAG_UPDATE.
function api.give_item(env, id, count, bag, slot)
    bag = bag or 0
    local b = env.__bags[bag]
    if not slot then
        for s = 1, b.size do if not b.items[s] then slot = s break end end
    end
    assert(slot, "api.give_item: bag " .. bag .. " is full")
    b.items[slot] = { id = id, count = count or 1 }
    api.fire(env, "BAG_UPDATE", bag)
    return slot
end
function api.set_bag(env, bag, size) env.__bags[bag] = env.__bags[bag] or { items = {} }; env.__bags[bag].size = size end

-- --------------------------------------------------------------------------------------------
-- Merchant, bank, auction house
-- --------------------------------------------------------------------------------------------

-- The stock MerchantFrame_UpdateMerchantInfo, reduced to what addons read back.
function api.__stock_merchant_update(env)
    local m = env.__merchant
    local n = m and #m.items or 0
    local page = env.MerchantFrame.page or 1
    for i = 1, env.MERCHANT_ITEMS_PER_PAGE do
        local index = (page - 1) * env.MERCHANT_ITEMS_PER_PAGE + i
        local name, ib, money = env["MerchantItem" .. i .. "Name"], env["MerchantItem" .. i .. "ItemButton"], env["MerchantItem" .. i .. "MoneyFrame"]
        if index <= n then
            local d = api.item(env, m.items[index].id) or {}
            name:SetText(d.name); ib:Show(); money:Show()
            env["MerchantItem" .. i .. "ItemButtonIconTexture"]:SetTexture(d.icon)
        else
            name:SetText(""); ib:Hide(); money:Hide()
        end
    end
end

-- m = { items = { { id = 2589, price = 100 }, ... }, repair = true, repairCost = 1234 }
function api.open_merchant(env, m)
    env.__merchant = m or { items = {} }
    env.__merchant.items = env.__merchant.items or {}
    env.MerchantFrame.page, env.MerchantFrame.selectedTab = 1, 1
    env.MerchantFrame:Show()
    api.fire(env, "MERCHANT_SHOW")
    local ok, err = xpcall(function() env.MerchantFrame_UpdateMerchantInfo() end, traceback)
    if not ok then table.insert(env.__errors, "MerchantFrame_UpdateMerchantInfo: " .. err) end
end
function api.close_merchant(env)
    env.MerchantFrame:Hide()
    api.fire(env, "MERCHANT_CLOSED")
    env.__merchant = nil
end

function api.open_bank(env) env.BankFrame:Show(); api.fire(env, "BANKFRAME_OPENED") end
function api.close_bank(env) env.BankFrame:Hide(); api.fire(env, "BANKFRAME_CLOSED") end


-- list = { { id, count, buyout, owner }, ... }; fires AUCTION_ITEM_LIST_UPDATE
function api.browse_auctions(env, list)
    env.__auctions = {}
    for _, a in ipairs(list) do
        table.insert(env.__auctions, { id = a.id or a[1], count = a.count or a[2] or 1, buyout = a.buyout or a[3], owner = a.owner or a[4] })
    end
    api.fire(env, "AUCTION_ITEM_LIST_UPDATE")
end

-- --------------------------------------------------------------------------------------------
-- Events, time, chat routing
-- --------------------------------------------------------------------------------------------

-- Dispatch an event to every frame that registered it (registration order), setting the
-- globals event, this and arg1..arg9 as 1.12 does.
function api.fire(env, ev, ...)
    if not api.EVENTS[ev] then
        table.insert(env.__errors, "api.fire: '" .. tostring(ev) .. "' is not a 1.12 event (test bug?)")
    end
    table.insert(env.__events_fired, ev)
    local args = { ... }
    local targets = {}
    for _, f in ipairs(env.__evreg[ev] or {}) do table.insert(targets, f) end
    for _, f in ipairs(env.__allevents) do table.insert(targets, f) end
    for _, f in ipairs(targets) do
        local s = ST[f]
        if (s.events[ev] or s.allEvents) and s.scripts.OnEvent then runScript(f, "OnEvent", args, ev) end
    end
end

local function busOf(x)
    if getmetatable(x) == Bus then return x end
    return x.__bus
end
api.bus_of = busOf

-- Deliver queued chat / addon messages.
function api.pump(x) return busOf(x):pump() end

-- Advance the shared clock by 'seconds' in steps of 'step' (default 0.1). Every client on the
-- bus runs its visible OnUpdate scripts with arg1 = elapsed; chat is delivered after each step.
function api.tick(x, seconds, step)
    local bus = busOf(x)
    step = step or 0.1
    bus:pump()
    local left = seconds or 0
    while left > 1e-9 do
        local dt = math.min(step, left)
        left = left - dt
        bus.now = bus.now + dt
        for _, env in ipairs(bus.clients) do
            local list = {}
            for _, f in ipairs(env.__onupdate) do list[#list + 1] = f end
            for _, f in ipairs(list) do
                if ST[f].scripts.OnUpdate and isVisible(f) then runScript(f, "OnUpdate", { dt }) end
            end
        end
        bus:pump()
    end
end

-- Chat routing (called by SendChatMessage after validation).
function api.__route_chat(env, msg, kind, target)
    local bus = env.__bus
    local me = env.__name
    if string.sub(msg, 1, 5) == ".wnl " or msg == ".wnl" then
        local line = string.sub(msg, 6)
        table.insert(env.__wnl, line)
        local cmd, rest = string.match(line, "^(%S+)%s*(.*)$")
        local h = env.__server_handlers[cmd or ""] or env.__server_handlers["*"]
        if h then
            bus:later(function()
                local ok, err = xpcall(function() h(rest, cmd, line) end, traceback)
                if not ok then table.insert(env.__errors, "server handler for '" .. tostring(cmd) .. "': " .. err) end
            end)
        end
        return
    end
    msg = bus:serverText(msg)
    if msg == "" then return end
    table.insert(bus.log, { from = me, kind = kind, msg = msg, target = target })
    if kind == "SAY" or kind == "YELL" or kind == "EMOTE" then
        for _, e in ipairs(bus.clients) do bus:deliver(e, "CHAT_MSG_" .. kind, msg, me, "Common") end
    elseif kind == "CHANNEL" then
        local _, chName = env.GetChannelName(tonumber(target) or 0)
        if not chName then
            bus:deliver(env, "CHAT_MSG_SYSTEM", "You are not in channel " .. tostring(target) .. ".")
            return
        end
        for e in pairs(bus:channelMembers(chName)) do
            local id = e.GetChannelName(chName)
            bus:deliver(e, "CHAT_MSG_CHANNEL", msg, me, "", id .. ". " .. chName, "", "", 0, id, chName)
        end
    elseif kind == "WHISPER" then
        local to = bus.by_name[target or ""]
        if not to then
            bus:deliver(env, "CHAT_MSG_SYSTEM", "No player named '" .. tostring(target) .. "' is currently playing.")
            return
        end
        bus:deliver(to, "CHAT_MSG_WHISPER", msg, me, "")
        bus:deliver(env, "CHAT_MSG_WHISPER_INFORM", msg, target, "")
    elseif kind == "PARTY" or kind == "RAID" or kind == "GUILD" then
        for _, e in ipairs(api.group_members(env, kind)) do bus:deliver(e, "CHAT_MSG_" .. kind, msg, me, "") end
    end
end

-- Clients that receive a PARTY / RAID / GUILD message from env (env included).
function api.group_members(env, kind)
    local out = {}
    if kind == "GUILD" then
        if not env.__guild then return out end
        for _, e in ipairs(env.__bus.clients) do
            if e.__guild and e.__guild.name == env.__guild.name then table.insert(out, e) end
        end
        return out
    end
    local g = env.__group
    if kind == "RAID" and not (g and g.kind == "raid") then return out end
    if not g then
        if kind == "PARTY" and env.GetNumPartyMembers() > 0 then table.insert(out, env) end
        return out
    end
    for _, e in ipairs(g.members) do table.insert(out, e) end
    return out
end

-- Put clients in one party (kind "party", up to 5) or raid ("raid"). Fires the roster events.
function api.group(envs, kind)
    kind = kind or "party"
    local g = { kind = kind, members = envs }
    for _, e in ipairs(envs) do
        e.__group = g
        for k in pairs(e.__units) do
            if string.find(k, "^party") or string.find(k, "^raid") then e.__units[k] = nil end
        end
        local i = 0
        for _, o in ipairs(envs) do
            if o ~= e and i < 4 then i = i + 1; e.__units["party" .. i] = shallow(o.__units.player) end
        end
        if kind == "raid" then
            for j, o in ipairs(envs) do e.__units["raid" .. j] = (o == e) and e.__units.player or shallow(o.__units.player) end
        end
    end
    for _, e in ipairs(envs) do api.fire(e, kind == "raid" and "RAID_ROSTER_UPDATE" or "PARTY_MEMBERS_CHANGED") end
end

-- Answer ".wnl <cmd>" lines the client sends: fn(args, cmd, line), run on the next pump.
-- cmd "*" catches all.
function api.on_server(env, cmd, fn) env.__server_handlers[cmd] = fn end

--[[ Deliver a Wenilla server packet the way the server does (see WenillaCore.lua):
     system  (default) CHAT_MSG_SYSTEM "WNL\t<TAG> <body>"
     addon   CHAT_MSG_ADDON prefix "WNL", body "<TAG> <body>", sent as the player themself
     whisper CHAT_MSG_WHISPER "WNL\t..." from the reserved sender "Wenilla"
   opts.handshake (default true): greet with "HI <version>" first when not yet connected.
   opts.chunk = n: split the body into "<TAG> <seq> <i>/<n> <part>" pieces of n bytes.
   opts.version: server version for the greeting (default "1"). ]]
local seqCounter = 0
function api.server_packet(env, tag, body, opts)
    opts = opts or {}
    local function send(text)
        local via = opts.via or "system"
        if via == "addon" then
            api.fire(env, "CHAT_MSG_ADDON", "WNL", text, "WHISPER", env.__name)
        elseif via == "whisper" then
            api.fire(env, "CHAT_MSG_WHISPER", "WNL\t" .. text, "Wenilla", "")
        else
            api.fire(env, "CHAT_MSG_SYSTEM", "WNL\t" .. text)
        end
    end
    if opts.handshake ~= false and env.WenillaCore and not env.WenillaCore.connected then
        send("HI " .. (opts.version or "1") .. (opts.addons and (" " .. opts.addons) or ""))
    end
    if tag == "HI" then send("HI " .. (body or "1")) return end
    body = body or ""
    if opts.chunk and string.len(body) > opts.chunk then
        seqCounter = seqCounter + 1
        local parts = {}
        for i = 1, string.len(body), opts.chunk do table.insert(parts, string.sub(body, i, i + opts.chunk - 1)) end
        local order = opts.order or {}
        if not order[1] then for i = 1, #parts do order[i] = i end end
        for _, i in ipairs(order) do send(tag .. " " .. seqCounter .. " " .. i .. "/" .. #parts .. " " .. parts[i]) end
    else
        send(tag .. " " .. body)
    end
    api.pump(env)
end

-- The server greeting alone; WenillaCore.connected becomes true and it answers ".wnl hi <ver>".
function api.connect(env, version, addons)
    api.server_packet(env, "HI", (version or "1") .. (addons and (" " .. addons) or ""), { handshake = false })
end

-- --------------------------------------------------------------------------------------------
-- Slash commands (ChatEdit_ParseText from 1.12 ChatFrame.lua)
-- --------------------------------------------------------------------------------------------

function api.slash(env, text)
    local command = string.gsub(text, "^(/[^%s]+)%s(.*)$", "%1", 1)
    local msg = ""
    if command ~= text then msg = string.sub(text, string.len(command) + 2) end
    command = string.upper(string.gsub(command, "%s+", ""))
    for key, fn in pairs(env.SlashCmdList) do
        local i = 1
        local cmd = env["SLASH_" .. key .. i]
        while cmd do
            if string.upper(cmd) == command then
                local ok, err = xpcall(function() fn(msg) end, traceback)
                if not ok then table.insert(env.__errors, "slash " .. text .. ": " .. err) end
                return true
            end
            i = i + 1
            cmd = env["SLASH_" .. key .. i]
        end
    end
    return false
end

-- { { key = "PERSONA", commands = { "/persona", "/rp" } }, ... } sorted by key
function api.slash_commands(env)
    local out = {}
    for key in pairs(env.SlashCmdList) do
        local cmds, i = {}, 1
        while env["SLASH_" .. key .. i] do table.insert(cmds, env["SLASH_" .. key .. i]); i = i + 1 end
        table.insert(out, { key = key, commands = cmds })
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- Escape: hide the shown frames listed in UISpecialFrames (CloseWindows).
function api.press_escape(env)
    local closed = false
    for _, n in ipairs(env.UISpecialFrames) do
        local f = env[n]
        if f and f:IsShown() then f:Hide(); closed = true end
    end
    return closed
end

-- Click a StaticPopup button (1 = accept, 2 = cancel).
function api.popup_click(env, which, button)
    local d = env.StaticPopupDialogs[which]
    local p = env.StaticPopup1
    assert(d and p.which == which and p:IsShown(), "api.popup_click: popup " .. tostring(which) .. " is not shown")
    local fn = (button == 2) and d.OnCancel or d.OnAccept
    p:Hide()
    p.which = nil
    if fn then
        local save = env.this
        env.this = p
        local ok, err = xpcall(function() fn(p.data) end, traceback)
        env.this = save
        if not ok then table.insert(env.__errors, "popup " .. which .. ": " .. err) end
    end
end

-- --------------------------------------------------------------------------------------------
-- Nameplates: 1.12 plates are unnamed children of WorldFrame whose first region is the
-- Nameplate-Border texture, regions border, glow, name, level, boss, raid; first child the
-- health bar.
-- --------------------------------------------------------------------------------------------

function api.add_nameplate(env, def)
    def = def or {}
    local p = newObject(env, "Button", nil, env.WorldFrame)
    local border = newObject(env, "Texture", nil, p, true); M.SetTexture(border, "Interface\\Tooltips\\Nameplate-Border")
    local glow = newObject(env, "Texture", nil, p, true); M.SetTexture(glow, "Interface\\Tooltips\\Nameplate-Glow")
    local name = newObject(env, "FontString", nil, p, true); M.SetText(name, def.name or "Defias Thug")
    local level = newObject(env, "FontString", nil, p, true); M.SetText(level, tostring(def.level or 10))
    M.SetTextColor(level, unpack(def.levelColor or { 1, 1, 1 }))
    local boss = newObject(env, "Texture", nil, p, true); if not def.boss then ST[boss].shown = false end
    local raid = newObject(env, "Texture", nil, p, true); ST[raid].shown = false
    local hb = newObject(env, "StatusBar", nil, p)
    M.SetMinMaxValues(hb, 0, def.healthMax or 100)
    M.SetValue(hb, def.health or def.healthMax or 100)
    return p
end

-- --------------------------------------------------------------------------------------------
-- Loading addons
-- --------------------------------------------------------------------------------------------

function api.read_toc(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local meta, files = {}, {}
    for line in f:lines() do
        line = string.gsub(line, "\r$", "")
        local k, v = string.match(line, "^##%s*([^:]+):%s*(.-)%s*$")
        if k then meta[k] = v
        elseif not string.match(line, "^%s*$") and not string.match(line, "^#") then
            table.insert(files, (string.gsub(string.gsub(line, "^%s+", ""), "%s+$", "")))
        end
    end
    f:close()
    return { meta = meta, files = files }
end

local function splitList(s)
    local out = {}
    for x in string.gmatch(s or "", "[^,%s]+") do table.insert(out, x) end
    return out
end

-- Run one file in the client: Lua 5.0 guard (once per file per run), then load + run.
-- Returns true when it ran clean.
api.__guard_cache = {}
function api.run_file(env, path, label)
    label = label or path
    local ok = true
    local issues = api.__guard_cache[path]
    if not issues then issues = api.guard.scan_file(path); api.__guard_cache[path] = issues end
    for _, it in ipairs(issues) do
        table.insert(env.__errors, "lua5.0 guard: " .. label .. ":" .. it.line .. ": " .. it.msg)
        ok = false
    end
    local chunk, err = loadfile(path)
    if not chunk then
        table.insert(env.__errors, "syntax: " .. tostring(err))
        return false
    end
    setfenv(chunk, env)
    local ran, rerr = xpcall(chunk, traceback)
    if not ran then table.insert(env.__errors, "loading " .. label .. ": " .. rerr) ok = false end
    return ok
end

-- Load one addon folder: every file of its .toc in order, then its SavedVariables, then
-- ADDON_LOADED. Dependencies are not followed (see api.load_with_deps).
function api.load_addon(env, dir)
    dir = string.gsub(dir, "/+$", "")
    local name = string.match(dir, "([^/\\]+)$")
    if env.__addons[name] then return true end
    local toc = api.read_toc(dir .. "/" .. name .. ".toc")
    if not toc then
        table.insert(env.__errors, "load_addon: no " .. name .. ".toc in " .. dir)
        return false
    end
    env.__addons[name] = { meta = toc.meta, dir = dir, files = toc.files }
    table.insert(env.__addon_order, name)
    local ok = true
    for _, file in ipairs(toc.files) do
        local rel = string.gsub(file, "\\", "/")
        if string.match(string.lower(rel), "%.xml$") then
            table.insert(env.__errors, "load_addon: " .. name .. "/" .. rel .. " is XML; the sim runs Lua only")
            ok = false
        else
            ok = api.run_file(env, dir .. "/" .. rel, name .. "/" .. rel) and ok
        end
    end
    -- SavedVariables are restored after the addon's files run (1.12 order)
    local svs = splitList(toc.meta.SavedVariables)
    for _, v in ipairs(splitList(toc.meta.SavedVariablesPerCharacter)) do table.insert(svs, v) end
    env.__addons[name].saved = svs
    for _, sv in ipairs(svs) do
        if env.__saved[sv] ~= nil then env[sv] = deepcopy(env.__saved[sv]) end
    end
    if name == "WenillaCore" then api.watch_core(env) end
    api.fire(env, "ADDON_LOADED", name)
    return ok
end

-- WenillaCore swallows handler errors in pcall and reports them through W:Error (silent unless
-- debug is on). Record them as client errors so tests see them.
function api.watch_core(env)
    local W = rawget(env, "WenillaCore")
    if not W or W.__simWatched then return end
    W.__simWatched = true
    local orig = W.Error
    W.Error = function(self, where, err)
        table.insert(env.__errors, "WenillaCore caught an error in " .. tostring(where) .. ": " .. api.explain(err))
        return orig(self, where, err)
    end
end

function api.addons_dir(env) return (env.__repo or api.repo) .. "/Data/Interface/AddOns" end

-- Load an addon and (first) its Dependencies / RequiredDeps and installed OptionalDeps.
function api.load_with_deps(env, name)
    local root = api.addons_dir(env)
    if env.__addons[name] then return true end
    local toc = api.read_toc(root .. "/" .. name .. "/" .. name .. ".toc")
    if not toc then
        table.insert(env.__errors, "load_with_deps: addon " .. name .. " not found in " .. root)
        return false
    end
    for _, field in ipairs({ "Dependencies", "RequiredDeps", "Dependancies", "OptionalDeps" }) do
        for _, dep in ipairs(splitList(toc.meta[field])) do
            if fileExists(root .. "/" .. dep .. "/" .. dep .. ".toc") then api.load_with_deps(env, dep) end
        end
    end
    return api.load_addon(env, root .. "/" .. name)
end

-- Every addon folder with a .toc (blizzard_* skipped), in the client's order: alphabetical
-- ("!" first), dependencies before dependents.
function api.suite_names(env)
    local names = {}
    for _, n in ipairs(listDir(api.addons_dir(env))) do
        if not string.match(string.lower(n), "^blizzard_") and fileExists(api.addons_dir(env) .. "/" .. n .. "/" .. n .. ".toc") then
            table.insert(names, n)
        end
    end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    return names
end
function api.load_suite(env, names)
    for _, n in ipairs(names or api.suite_names(env)) do api.load_with_deps(env, n) end
    return env.__addon_order
end

-- The login sequence after all addons loaded.
function api.login(env)
    api.fire(env, "VARIABLES_LOADED")
    api.fire(env, "PLAYER_LOGIN")
    api.fire(env, "PLAYER_ENTERING_WORLD")
    api.pump(env)
end

-- What the client would write to SavedVariables on logout.
function api.saved(env)
    local out = {}
    for _, a in pairs(env.__addons) do
        for _, sv in ipairs(a.saved or {}) do out[sv] = deepcopy(rawget(env, sv)) end
    end
    return out
end

-- Log out and back in: a fresh client with the same options, the saved variables carried over
-- and the same addons loaded. The old client leaves the bus.
function api.relog(env, extra)
    local opts = shallow(env.__opts)
    for k, v in pairs(extra or {}) do opts[k] = v end
    opts.saved = api.saved(env)
    -- client settings (Config.wtf) and character state (server side) carry over too
    if not (extra and extra.cvars) then opts.cvars = shallow(env.__cvars) end
    if not (extra and extra.money) then opts.money = env.__money end
    api.remove_client(env)
    local new = api.new_client(opts)
    if not (extra and extra.bags) then new.__bags = deepcopy(env.__bags) end
    for _, n in ipairs(env.__ignores) do table.insert(new.__ignores, n) end
    for _, n in ipairs(env.__addon_order) do api.load_addon(new, env.__addons[n].dir) end
    api.login(new)
    return new
end

function api.remove_client(env)
    local bus = env.__bus
    for i, e in ipairs(bus.clients) do if e == env then table.remove(bus.clients, i) break end end
    bus.by_name[env.__name] = nil
    for _, c in pairs(bus.channels) do c.members[env] = nil end
end

-- --------------------------------------------------------------------------------------------
-- Reading the screen
-- --------------------------------------------------------------------------------------------

-- Lines of a tooltip as visible text: "Left" or "Left  =  Right".
function api.tooltip_lines(env, tip)
    tip = tip or env.GameTooltip
    local s = ST[tip]
    local out = {}
    for i = 1, (s.numLines or 0) do
        local l = env[(s.name or "Tooltip") .. "TextLeft" .. i]
        local r = env[(s.name or "Tooltip") .. "TextRight" .. i]
        local lt, rt = l and ST[l].text, r and ST[r].text
        local line = api.visible(lt or "")
        if rt and rt ~= "" then line = line .. "  =  " .. api.visible(rt) end
        table.insert(out, line)
    end
    return out
end
function api.tooltip_text(env, tip) return table.concat(api.tooltip_lines(env, tip), "\n") end

-- Everything printed to the default chat frame, colour codes removed.
function api.chat_lines(env)
    local out = {}
    for _, l in ipairs(env.__chat) do table.insert(out, api.visible(l)) end
    return out
end
function api.chat_text(env) return table.concat(api.chat_lines(env), "\n") end

-- Texts of every visible FontString (and button label) under 'root' (default: everything).
function api.visible_texts(env, root)
    local out = {}
    local function under(o)
        if not root then return true end
        local s = ST[o]
        while s do
            if s.parent == root then return true end
            s = s.parent and ST[s.parent]
        end
        return false
    end
    for _, r in ipairs(env.__regions) do
        local s = ST[r]
        if s.otype == "FontString" and s.text and s.text ~= "" and s.shown and (not s.parent or isVisible(s.parent)) and under(r) then
            table.insert(out, api.visible(s.text))
        end
    end
    return out
end

-- The first visible Button / CheckButton whose label (colour codes removed) is 'text'.
function api.find_button(env, text, root)
    for _, f in ipairs(env.__frames) do
        local s = ST[f]
        if (s.otype == "Button" or s.otype == "CheckButton") and s.text and api.visible(s.text) == text and isVisible(f) then
            if not root then return f end
            local p = s.parent
            while p do if p == root then return f end p = ST[p].parent end
        end
    end
    return nil
end

-- The visible FontString whose text contains 'needle' (plain), and the nearest clickable frame
-- (Button / CheckButton) above it.
function api.find_text(env, needle, root)
    for _, r in ipairs(env.__regions) do
        local s = ST[r]
        if s.otype == "FontString" and s.text and string.find(api.visible(s.text), needle, 1, true)
            and s.shown and s.parent and isVisible(s.parent) then
            local ok = not root
            local p = s.parent
            local button
            while p do
                local ps = ST[p]
                if not button and (ps.otype == "Button" or ps.otype == "CheckButton") then button = p end
                if p == root then ok = true end
                p = ps.parent
            end
            if ok then return r, button end
        end
    end
    return nil
end
-- Click / hover the button that shows 'needle'.
function api.click_text(env, needle, root, button)
    local r, b = api.find_text(env, needle, root)
    assert(b, "api.click_text: no visible button shows '" .. needle .. "'")
    return api.click(b, button)
end
function api.hover_text(env, needle, root)
    local r, b = api.find_text(env, needle, root)
    assert(b, "api.hover_text: no visible button shows '" .. needle .. "'")
    api.enter(b)
    return b
end

-- Is a visible text containing 'needle' (plain) on screen?
function api.screen_has(env, needle, root)
    for _, t in ipairs(api.visible_texts(env, root)) do
        if string.find(t, needle, 1, true) then return t end
    end
    return nil
end

-- Extensions: each devkit/sim/ext/<name>.lua returns function(api, helpers) and may push
-- function(env, B, opts) onto api.client_extensions (run inside api.new_client).
api.client_extensions = api.client_extensions or {}
do
    local files = {}
    for _, f in ipairs(listDir(HERE .. "ext")) do
        if string.match(f, "%.lua$") then table.insert(files, f) end
    end
    table.sort(files)
    for _, f in ipairs(files) do
        dofile(HERE .. "ext/" .. f)(api, { M = M, newObject = newObject, traceback = traceback, NOOP = NOOP })
    end
end

return api
