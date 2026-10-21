--[[
    WenillaCore.lua
    Classic+ native addon suite: addon registry, settings, server transport, art resolver.

    Written for the 1.12.1 client (Lua 5.0 rules: no '#', no '%' operator, no select(),
    handlers read the globals this/event/arg1..argN). Runs unchanged in the Open Vanilla web client.

    Addon ids are the folder names (Meters, Quests, Bags, ...) and, since 1.15, also the names
    players see. The older brand names (Chronicle, Compass, ...) still resolve through W.Id.

    Server transport (optional). Nothing is ever sent to the server until the server has
    greeted the client first, so a realm without telemetry support never sees a stray
    ".wnl ..." line in /say. Incoming lines:
        CHAT_MSG_ADDON   prefix "WNL", sent as the player themself     body = "<TAG> <payload>"
        CHAT_MSG_SYSTEM  text "WNL\t<TAG> <payload>"                    (hidden from chat)
        CHAT_MSG_WHISPER from the reserved sender "Wenilla", same text   (hidden from chat)
    <payload> is "<seq> <i>/<n> <body>" when chunked, otherwise the body itself.
    The server says "HI <version> [addon,addon,...]" first; commands go up as ".wnl <cmd>".
]]--

WenillaCore = WenillaCore or {}
local W = WenillaCore

W.version = "1.1.0"
W.connected = false
W.serverVersion = nil
W.modules = {}
W.chunkBuffer = {}
W.isVanillaMode = false
W.debug = false
W.PREFIX = "WNL"
W.SERVER_SENDER = "Wenilla"

-- Addon ids are the folder names, and since 1.15 they are also the names players see.
-- W.ORDER is the order of the Addons window; W.ADDONS holds the addons actually loaded (each
-- joins it when it calls W:RegisterAddon), in that order.
W.ORDER = {
    "Meters", "Quests", "Social", "Dungeons", "Achievements", "Chat", "Bags", "Mail", "Prices",
    "Vendor", "Plates", "Casting", "Threat", "Raid", "Guilds", "GuildHub", "Talents", "Loot", "Persona", "Essentials",
}
W.ADDONS = {}
-- Display names (kept as a table so addons can still look one up). Same as the id.
W.BRAND = {}
for _, id in ipairs(W.ORDER) do W.BRAND[id] = id end
-- The names before 1.15 still resolve, so saved settings and old slash commands keep working.
W.OLD_NAMES = {
    Chronicle = "Meters", Compass = "Quests", Vanguard = "Threat", Castline = "Casting",
    Concord = "Guilds", Vault = "Bags", Ledger = "Prices", Scrapper = "Vendor",
    Visage = "Plates", Rally = "Raid",
}
local BY_BRAND = {}
for brand, id in pairs(W.OLD_NAMES) do BY_BRAND[brand] = id end

-- Settings schemas registered by the addons themselves (see W:RegisterSchema).
W.schemas = {}

W.addonStates = {}

W.refreshers = {}        -- id -> function(active)
W.configCallbacks = {}   -- run once WenillaCore_Config exists
W.stats = { messagesReceived = 0, bytesReceived = 0, commandsSent = 0 }

local floor = math.floor
local strsub, strfind, strlen, strlower = string.sub, string.find, string.len, string.lower

-- -- Utilities -----------------------------------------------------------------

function W.Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Classic+|r " .. tostring(msg))
    end
end
local Print = W.Print

-- Plain split that keeps empty fields ("a,,b" -> "a", "", "b"). Returns the table and count.
function W.Split(str, delim)
    local out, n, pos = {}, 0, 1
    str = str or ""
    while true do
        local a = strfind(str, delim, pos, 1)
        n = n + 1
        if not a then
            out[n] = strsub(str, pos)
            break
        end
        out[n] = strsub(str, pos, a - 1)
        pos = a + strlen(delim)
    end
    return out, n
end

function W.Trim(s)
    local _, _, t = strfind(s or "", "^%s*(.-)%s*$")
    return t or ""
end

-- 1234567 -> "1.23M", 12345 -> "12.3k"
function W.Short(n)
    n = tonumber(n) or 0
    if n >= 1000000 then return string.format("%.2fM", n / 1000000) end
    if n >= 10000 then return string.format("%.1fk", n / 1000) end
    return tostring(floor(n + 0.5))
end

function W.Clock(sec)
    sec = floor(tonumber(sec) or 0)
    local m = floor(sec / 60)
    local s = sec - m * 60
    if s < 10 then return m .. ":0" .. s end
    return m .. ":" .. s
end

-- Normalise "Chronicle" or "Meters" to the folder id.
function W.Id(name)
    if not name then return nil end
    if W.addonStates[name] ~= nil then return name end
    return BY_BRAND[name] or name
end

-- -- Config & settings ---------------------------------------------------------

local CONFIG_VERSION = 2

-- Called on VARIABLES_LOADED (1.12 client) or by the web loader after it restores
-- SavedVariables. Safe to call more than once.
function W:InitConfig()
    if type(WenillaCore_Config) ~= "table" then WenillaCore_Config = {} end
    local c = WenillaCore_Config
    if (c.version or 0) < CONFIG_VERSION then
        -- v1 shipped with the demo stream on by default; real players saw invented numbers.
        c.demoMode = false
        -- v1 keyed addon states by display name.
        if type(c.addons) == "table" then
            local moved = {}
            for k, v in pairs(c.addons) do moved[W.Id(k)] = v end
            c.addons = moved
        end
        c.version = CONFIG_VERSION
    end
    c.addons = c.addons or {}
    c.settings = c.settings or {}
    c.positions = c.positions or {}
    for id, v in pairs(c.addons) do
        if W.addonStates[id] ~= nil then W.addonStates[id] = v and true or false end
    end
    self.isVanillaMode = c.pureVanilla and true or false
    if not self.configReady then
        self.configReady = true
        for _, fn in ipairs(self.configCallbacks) do
            local ok, err = pcall(fn, c)
            if not ok then self:Error("config", err) end
        end
    end
    self:ApplyPositions()
    self:RefreshAll()
    return c
end

function W:OnConfig(fn)
    if self.configReady then fn(WenillaCore_Config) else table.insert(self.configCallbacks, fn) end
end

-- Per-addon settings table. AddonManager.lua supplies the defaults.
function W:Settings(id)
    if ClassicPlus_Manager and ClassicPlus_Manager.GetSettings then
        return ClassicPlus_Manager:GetSettings(id)
    end
    return {}
end

function W:Setting(id, key, default)
    local v = self:Settings(id)[key]
    if v == nil then return default end
    return v
end

-- True when the addon should be doing its work and showing its UI.
function W:IsActive(id)
    id = W.Id(id)
    if self.isVanillaMode then return false end
    if self.addonStates[id] == false then return false end
    return self:Setting(id, "enabled", true) and true or false
end

-- Describe an addon's settings for the Addons window, and supply their defaults.
-- schema = { title=, desc=, icon=, defaults = { key = value }, options = {
--     { key=, label=, sub=, type = "switch" (default) | "choice" | "slider",
--       choices = { {value=, label=} } (choice), min=, max=, step=, fmt= (slider) } } }
function W:RegisterSchema(id, schema)
    self.schemas[id] = schema
    self:Join(id)
end

-- Add an addon id to W.ADDONS (once), keeping W.ORDER's order; unknown ids go last.
local function rank(id)
    for i, x in ipairs(W.ORDER) do if x == id then return i end end
    return 1000
end
function W:Join(id)
    for _, x in ipairs(self.ADDONS) do if x == id then return end end
    local pos = table.getn(self.ADDONS) + 1
    for i, x in ipairs(self.ADDONS) do
        if rank(id) < rank(x) then pos = i break end
    end
    table.insert(self.ADDONS, pos, id)
    if not self.BRAND[id] then self.BRAND[id] = id end
    if self.addonStates[id] == nil then
        local saved = WenillaCore_Config and WenillaCore_Config.addons and WenillaCore_Config.addons[id]
        if saved == nil then self.addonStates[id] = true else self.addonStates[id] = saved and true or false end
    end
end

function W:RegisterAddon(id, refresh)
    self:Join(id)
    self.refreshers[id] = refresh
    if self.configReady then self:Refresh(id) end
end

function W:Refresh(id)
    id = W.Id(id)
    local fn = self.refreshers[id]
    if fn then
        local ok, err = pcall(fn, self:IsActive(id))
        if not ok then self:Error(id, err) end
    end
end

function W:RefreshAll()
    for _, id in ipairs(self.ADDONS) do self:Refresh(id) end
end

function W:SetAddonEnabled(name, enabled)
    local id = W.Id(name)
    enabled = enabled and true or false
    self.addonStates[id] = enabled
    if WenillaCore_Config then
        WenillaCore_Config.addons = WenillaCore_Config.addons or {}
        WenillaCore_Config.addons[id] = enabled
        local s = self:Settings(id)
        s.enabled = enabled
    end
    self:Refresh(id)
    if self.UpdateManagerUI then self:UpdateManagerUI() end
end

function W:SetVanillaMode(enabled)
    self.isVanillaMode = enabled and true or false
    if WenillaCore_Config then WenillaCore_Config.pureVanilla = self.isVanillaMode end
    if self.isVanillaMode and self.StopDemoStream then self:StopDemoStream(true) end
    self:RefreshAll()
    if self.isVanillaMode then
        Print("|cffffd100Pure Vanilla|r - every Classic+ addon is off.")
    else
        Print("|cff40ff40Classic+ Enhanced|r - native addons restored.")
    end
    if self.UpdateManagerUI then self:UpdateManagerUI() end
end

function W:ToggleVanillaMode()
    self:SetVanillaMode(not self.isVanillaMode)
end

function W:Error(where, err)
    if self.debug then Print("|cffff4040error in " .. tostring(where) .. ":|r " .. tostring(err)) end
end

-- -- Window positions ---------------------------------------------------------

W.movable = {}

-- Remember where the player drags a frame. key defaults to the frame name.
function W:SavePosition(frame, key)
    key = key or frame:GetName()
    if not key or not WenillaCore_Config then return end
    local x, y = frame:GetLeft(), frame:GetTop()
    if x and y then WenillaCore_Config.positions[key] = { x = x, y = y } end
end

function W:TrackPosition(frame, key)
    key = key or frame:GetName()
    self.movable[key] = frame
    self:ApplyPosition(frame, key)
end

function W:ApplyPosition(frame, key)
    local c = WenillaCore_Config
    local p = c and c.positions and c.positions[key]
    if p and p.x and p.y then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p.x, p.y)
    end
end

function W:ApplyPositions()
    for key, frame in pairs(self.movable) do self:ApplyPosition(frame, key) end
end

function W:ResetPositions()
    if WenillaCore_Config then WenillaCore_Config.positions = {} end
    for _, frame in pairs(self.movable) do
        if frame.defaultPoint then
            local d = frame.defaultPoint
            frame:ClearAllPoints()
            frame:SetPoint(d[1], d[2] or UIParent, d[3], d[4], d[5])
        end
    end
    Print("window positions reset.")
end

-- -- Art resolver --------------------------------------------------------------
-- The same textures ship twice: as TGA under the addon (the 1.12 client loads loose addon
-- art) and as BLP under Interface\ClassicPlus (the web client streams that path from the
-- server's Data folder). SetTexture returns 1/nil, so the first root that loads wins; when
-- neither does, the caller's stock fallback is used and the window still looks right.

W.ART_ROOTS = { "Interface\\AddOns\\WenillaCore\\Media\\", "Interface\\ClassicPlus\\" }
W.artRoot = nil   -- resolved root, or false when no custom art loads

local function tryRoots(tex, name)
    -- The remembered root first; then the other one for this texture alone. A patch that ships
    -- a piece in only one folder (an older patch-Z: some ring themes as TGA, not BLP) must still
    -- show it, so a miss in the remembered root is never final.
    if W.artRoot and tex:SetTexture(W.artRoot .. name) then return true end
    for _, root in ipairs(W.ART_ROOTS) do
        if root ~= W.artRoot and tex:SetTexture(root .. name) then
            if not W.artRoot then W.artRoot = root end
            return true
        end
    end
    if W.artRoot == nil then W.artRoot = false end
    return false
end

-- tex:SetTexture(custom art) or, failing that, fallback (a path, or {r,g,b,a}).
-- Returns true when the custom art loaded.
function W:Art(tex, name, fallback)
    local swap = WenillaCore_Layout and WenillaCore_Layout.art and WenillaCore_Layout.art[name]   -- UI Studio art swaps
    if swap and swap ~= "" and tryRoots(tex, swap) then return true end
    if tryRoots(tex, name) then return true end
    if type(fallback) == "table" then
        tex:SetTexture(fallback[1], fallback[2], fallback[3], fallback[4] or 1)
    elseif fallback then
        tex:SetTexture(fallback)
    else
        tex:SetTexture(nil)
    end
    return false
end

-- -- Tunables ----------------------------------------------------------------
-- A number (or string) an addon lets UI Studio change without code: W:Tune("Loot.recap.offsetX", 110)
-- returns Layout.lua's value for the key, else the default. The studio lists every W:Tune in the source.
W.tunables = W.tunables or {}
function W:Tune(key, default)
    W.tunables[key] = default
    local t = WenillaCore_Layout and WenillaCore_Layout.tune
    local v = t and t[key]
    if v ~= nil and (default == nil or type(v) == type(default)) then return v end
    return default
end

-- -- Transport -----------------------------------------------------------------

function W:RegisterModule(tag, callback)
    if not tag or not callback then return end
    self.modules[string.upper(tag)] = callback
end

-- Send ".wnl <cmd> <args>" to the server. Refused (returns nil) until the server has
-- greeted us, because on a realm without the hook the line would be said out loud.
-- Every ".wnl" line is a SAY as far as the server's chat flood guard is concerned (CMaNGOS
-- ChatFlood.MessageCount, 10 lines in one second mutes the player for 10 s), so at most
-- CMD_PER_SEC go up per second; the rest wait in a short queue (same line queued once).
W.CMD_PER_SEC = 4
W.cmdQueue = W.cmdQueue or {}
local cmdWindow, cmdCount, cmdPump = -10, 0, nil

local function sendNow(line)
    W.stats.commandsSent = W.stats.commandsSent + 1
    SendChatMessage(line, "SAY")
end

local function cmdRoom()
    local t = GetTime and GetTime() or 0
    if t - cmdWindow >= 1 then cmdWindow, cmdCount = t, 0 end
    return cmdCount < W.CMD_PER_SEC
end

local function drainCommands()
    while W.cmdQueue[1] and cmdRoom() do
        cmdCount = cmdCount + 1
        sendNow(table.remove(W.cmdQueue, 1))
    end
    if not W.cmdQueue[1] and cmdPump then cmdPump:Hide() end
end

function W:SendCommand(cmd, args)
    if self.isVanillaMode or not self.connected then return nil end
    local line = ".wnl " .. tostring(cmd)
    if args and args ~= "" then line = line .. " " .. tostring(args) end
    if not self.cmdQueue[1] and cmdRoom() then
        cmdCount = cmdCount + 1
        sendNow(line)
        return 1
    end
    for _, l in ipairs(self.cmdQueue) do if l == line then return 1 end end
    if table.getn(self.cmdQueue) >= 40 then table.remove(self.cmdQueue, 1) end
    table.insert(self.cmdQueue, line)
    if not cmdPump and CreateFrame then
        cmdPump = CreateFrame("Frame", "WenillaCore_CommandPump")
        cmdPump:SetScript("OnUpdate", drainCommands)
    end
    if cmdPump then cmdPump:Show() end
    return 1
end

-- Does the realm's greeting ("HI <version> <addons>") list this feature? Commands a realm
-- doesn't list are ignored there, so anything waiting on an answer checks this first.
function W:ServerHas(name)
    if not self.connected then return false end
    for _, x in ipairs(self.serverAddons or {}) do
        if x == name then return true end
    end
    return false
end

function W:Dispatch(tag, body)
    if self.isVanillaMode then return end
    local handler = self.modules[tag]
    if handler then
        local ok, err = pcall(handler, body or "")
        if not ok then self:Error(tag, err) end
    end
end

function W:HandlePayload(raw)
    if self.isVanillaMode or not raw or raw == "" then return end
    self.stats.messagesReceived = self.stats.messagesReceived + 1
    self.stats.bytesReceived = self.stats.bytesReceived + strlen(raw)

    if strsub(raw, 1, 1) == "\t" or strsub(raw, 1, 1) == " " then raw = strsub(raw, 2) end
    local sp = strfind(raw, " ", 1, 1)
    local tag = string.upper(sp and strsub(raw, 1, sp - 1) or raw)
    local rest = sp and strsub(raw, sp + 1) or ""

    if tag == "HI" then
        self:HandleHandshake(rest)
        return
    end

    -- chunked: "<seq> <i>/<n> <body>"
    -- (the server's seq is a number; a plain body like "Repairs 1/2 price" must not match)
    local _, _, seq, idx, total, body = strfind(rest, "^(%d+) (%d+)/(%d+) ?(.*)$")
    if seq and (tonumber(idx) < 1 or tonumber(idx) > tonumber(total) or tonumber(total) > 64) then seq = nil end
    if seq then
        idx, total = tonumber(idx), tonumber(total)
        if total <= 1 then
            self:Dispatch(tag, body)
            return
        end
        local key = tag .. ":" .. seq
        local buf = self.chunkBuffer[key]
        if not buf then
            buf = { total = total, chunks = {}, received = 0, t = GetTime() }
            self.chunkBuffer[key] = buf
        end
        if not buf.chunks[idx] then
            buf.chunks[idx] = body
            buf.received = buf.received + 1
        end
        if buf.received >= buf.total then
            self.chunkBuffer[key] = nil
            self:Dispatch(tag, table.concat(buf.chunks, "", 1, buf.total))
        end
        -- drop half-received messages older than 10 s
        for k, b in pairs(self.chunkBuffer) do
            if GetTime() - b.t > 10 then self.chunkBuffer[k] = nil end
        end
        return
    end
    self:Dispatch(tag, rest)
end

function W:HandleHandshake(payload)
    local parts = W.Split(payload, " ")
    self.serverVersion = parts[1] ~= "" and parts[1] or "1"
    self.serverAddons = parts[2] and W.Split(parts[2], ",") or {}
    local first = not self.connected
    self.connected = true
    if first then
        self:SendCommand("hi", self.version)
        Print("server telemetry connected (v" .. self.serverVersion .. ").")
    end
end

-- Addons can hide their own carrier traffic: function(event) return true to swallow it.
W.chatFilters = W.chatFilters or {}

local function isWnl(msg)
    local head = strsub(msg or "", 1, 4)
    return head == "WNL\t" or head == "WNL "
end

-- Hide the server's carrier lines from every chat window.
local origChatFrame_OnEvent = ChatFrame_OnEvent
if origChatFrame_OnEvent then
    function ChatFrame_OnEvent(ev)
        if ev == "CHAT_MSG_SYSTEM" and isWnl(arg1) then return end
        if ev == "CHAT_MSG_WHISPER" and arg2 == W.SERVER_SENDER and isWnl(arg1) then return end
        for _, f in ipairs(W.chatFilters) do
            if f(ev) then return end
        end
        return origChatFrame_OnEvent(ev)
    end
end

-- -- Events --------------------------------------------------------------------

local core = CreateFrame("Frame", "WenillaCore_Frame")
core:RegisterEvent("VARIABLES_LOADED")
core:RegisterEvent("PLAYER_ENTERING_WORLD")
core:RegisterEvent("CHAT_MSG_ADDON")
core:RegisterEvent("CHAT_MSG_SYSTEM")
core:RegisterEvent("CHAT_MSG_WHISPER")

core:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        W:InitConfig()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not W.configReady then W:InitConfig() end
        W:RefreshAll()
        if not W.welcomed then
            W.welcomed = true
            Print("native suite loaded - |cffffd100/addons|r for settings, |cffffd100/vanilla|r for pure 1.12.")
        end
        if WenillaCore_Config and WenillaCore_Config.demoMode and W.StartDemoStream then
            W:StartDemoStream(true)
        end
    elseif event == "CHAT_MSG_ADDON" then
        -- Only the server can make an addon message appear to come from ourselves.
        if arg1 == W.PREFIX and arg4 == UnitName("player") then W:HandlePayload(arg2) end
    elseif event == "CHAT_MSG_SYSTEM" then
        if isWnl(arg1) then W:HandlePayload(strsub(arg1, 5)) end
    elseif event == "CHAT_MSG_WHISPER" then
        if arg2 == W.SERVER_SENDER and isWnl(arg1) then W:HandlePayload(strsub(arg1, 5)) end
    end
end)

-- -- The Esc menu ---------------------------------------------------------------
-- Every suite button in the Game Menu goes through here, so they stack in one order under Macros
-- and above Log Out however many addons add one, and the menu grows to fit.
--   W:GameMenuAdd(name, text, onClick, order)   order: lower is higher up (AddOns 10)
--   W:GameMenuShow(name, show)                   hide or show one (the menu closes up)
W.gameMenu = {}

function W:GameMenuLayout()
    if not (GameMenuFrame and GameMenuButtonLogout) then return end
    local m = self.gameMenu
    if not m.baseHeight then
        m.baseHeight = GameMenuFrame:GetHeight() or 250
        -- the client's own Edit Mode and Support are disabled placeholders; ours (MicroMenu.lua)
        -- work, so the placeholders go and Macros hangs under Options where they started
        for _, b in ipairs({ BenillaGameMenuButtonEditMode, BenillaGameMenuButtonSupport }) do
            if b and b:IsShown() ~= nil then
                b:Hide()
                m.baseHeight = m.baseHeight - (b:GetHeight() or 20)
            end
        end
    end
    if BenillaGameMenuButtonEditMode and GameMenuButtonOptions and GameMenuButtonMacros then
        BenillaGameMenuButtonEditMode:Hide()
        if BenillaGameMenuButtonSupport then BenillaGameMenuButtonSupport:Hide() end
        GameMenuButtonMacros:ClearAllPoints()
        GameMenuButtonMacros:SetPoint("TOP", GameMenuButtonOptions, "BOTTOM", 0, -20)
    end
    table.sort(m, function(a, b) if a.order ~= b.order then return a.order < b.order end return a.seq < b.seq end)
    local above, n = GameMenuButtonMacros, 0
    for _, e in ipairs(m) do
        if e.show then
            if above then
                e.button:ClearAllPoints()
                e.button:SetPoint("TOP", above, "BOTTOM", 0, -1)
            end
            e.button:Show()
            above, n = e.button, n + 1
        else
            e.button:Hide()
        end
    end
    if above then
        GameMenuButtonLogout:ClearAllPoints()
        GameMenuButtonLogout:SetPoint("TOP", above, "BOTTOM", 0, -1)
    end
    GameMenuFrame:SetHeight(m.baseHeight + 24 * n)
end

function W:GameMenuAdd(name, text, onClick, order)
    if not GameMenuFrame then return end
    local entry
    for _, e in ipairs(self.gameMenu) do if e.name == name then entry = e end end
    if not entry then
        local btn = getglobal(name) or CreateFrame("Button", name, GameMenuFrame, "GameMenuButtonTemplate")
        entry = { name = name, button = btn, seq = table.getn(self.gameMenu) + 1, show = true }
        table.insert(self.gameMenu, entry)
    end
    entry.order = order or 50
    entry.button:SetText(text)
    entry.button:SetScript("OnClick", function()
        if PlaySound then PlaySound("igMainMenuOption") end
        if HideUIPanel then HideUIPanel(GameMenuFrame) else GameMenuFrame:Hide() end
        onClick()
    end)
    self:GameMenuLayout()
    return entry.button
end

function W:GameMenuShow(name, show)
    for _, e in ipairs(self.gameMenu) do
        if e.name == name then
            e.show = show and true or false
            self:GameMenuLayout()
            return
        end
    end
end

-- -- Slash commands ------------------------------------------------------------

SLASH_VANILLA1 = "/vanilla"
SLASH_VANILLA2 = "/purevanilla"
SlashCmdList["VANILLA"] = function() W:ToggleVanillaMode() end

SLASH_WENILLA1 = "/wnl"
SLASH_WENILLA2 = "/wenilla"
SlashCmdList["WENILLA"] = function(msg)
    msg = strlower(W.Trim(msg))
    if msg == "demo" then
        if W.ToggleDemoStream then W:ToggleDemoStream() end
    elseif msg == "vanilla" then
        W:ToggleVanillaMode()
    elseif msg == "addons" or msg == "menu" or msg == "options" then
        if ClassicPlus_ToggleManager then ClassicPlus_ToggleManager() end
    elseif msg == "reset" then
        W:ResetPositions()
    elseif msg == "debug" then
        W.debug = not W.debug
        Print("debug " .. (W.debug and "on" or "off"))
    elseif msg == "status" then
        Print("mode: " .. (W.isVanillaMode and "Pure Vanilla" or "Classic+ Enhanced")
            .. "  |  server telemetry: " .. (W.connected and ("|cff40ff40on|r v" .. W.serverVersion) or "|cff909090off|r")
            .. "  |  art: " .. (W.artRoot and W.artRoot or "stock"))
        Print("packets " .. W.stats.messagesReceived .. " (" .. W.stats.bytesReceived .. " bytes), commands " .. W.stats.commandsSent)
    else
        Print("/addons settings  |  /vanilla toggle pure 1.12  |  /wnl demo  |  /wnl reset (windows)  |  /wnl status")
    end
end
