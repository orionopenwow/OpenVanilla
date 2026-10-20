--[[
    Core.lua  (Open Vanilla staff console)
    The in-game version of the realm's GM console (hetzner/gm_console.py): who is online, where
    they are, what to do about them, bug reports, and any GM command.

    It is for game masters only and stays out of sight for everyone else: no minimap button, no
    entry in the Addons window or the Workshop (## X-Unlisted in the .toc), nothing printed at load.
    /ovgm (or /gmc) asks the realm ".wnl gm hi"; the realm answers "GM OK <account level>" to a game
    master and nothing at all to anyone else. Only that answer opens the window, and it is
    remembered until the next /reload. A player who types /ovgm sees nothing happen.

    Client -> server (as ".wnl gm <cmd>", via WenillaCore:SendCommand)
        gm hi        GM      "OK <accountLevel>"
        gm roster    GR      rows split by ';', each
                             name,level,race,class,gender,zone,map,x,y,z,hp,maxhp,power,maxpower,
                             powerType,copper,account,accountLevel,mutedSec,state,combat,latency,gmOn,guild,ip
                             (state 0 alive, 1 dead, 2 ghost; zone is the AreaTable zone id)
        gm bugs      GB      rows split by ';', each id,created,name,level,class,map,zone,x,y,z,category,text
    Everything the console does to a player is an ordinary GM chat command (".kick <name>", ...),
    so the realm checks the GM's rights for every one of them exactly as if it were typed.

    Lua 5.0 rules (1.12 client): no '#', no '%' operator, no select(), handlers read this/event/arg1.
]]--

local W = WenillaCore

OVConsole = OVConsole or {}
local C = OVConsole

local strfind, strsub, strlower, strlen, gsub = string.find, string.sub, string.lower, string.len, string.gsub
local getn, floor = table.getn, math.floor

C.gm = false          -- the realm said "GM OK" this session
C.level = 0           -- the GM's account level
C.wantOpen = false    -- /ovgm is waiting for the realm's answer
C.roster = {}         -- parsed GR rows
C.byName = {}
C.rosterAt = nil      -- GetTime() of the last GR
C.bugs = {}
C.out = {}            -- recent system lines (the output strip)
C.history = {}        -- commands run from the command box, newest last
C.gear = {}           -- name -> { [slot] = { link=, tex= } } from the last inspect
C.selected = nil      -- the picked player's name
C.sortKey, C.sortDesc = "name", false
C.filter = ""
C.REFRESH = 5         -- seconds between roster requests while the window is open
C.MAX_OUT = 60

C.RACES = { [1] = "Human", [2] = "Orc", [3] = "Dwarf", [4] = "Night Elf", [5] = "Undead", [6] = "Tauren", [7] = "Gnome", [8] = "Troll" }
C.CLASSES = { [1] = "Warrior", [2] = "Paladin", [3] = "Hunter", [4] = "Rogue", [5] = "Priest", [7] = "Shaman", [8] = "Mage", [9] = "Warlock", [11] = "Druid" }
C.POWER = { [0] = "Mana", [1] = "Rage", [2] = "Focus", [3] = "Energy" }
C.ZONES = {
    [1] = "Dun Morogh", [3] = "Badlands", [4] = "Blasted Lands", [8] = "Swamp of Sorrows", [10] = "Duskwood", [11] = "Wetlands",
    [12] = "Elwynn Forest", [14] = "Durotar", [15] = "Dustwallow Marsh", [16] = "Azshara", [17] = "The Barrens", [25] = "Blackrock Mountain",
    [28] = "Western Plaguelands", [33] = "Stranglethorn Vale", [36] = "Alterac Mountains", [38] = "Loch Modan", [40] = "Westfall",
    [41] = "Deadwind Pass", [44] = "Redridge Mountains", [45] = "Arathi Highlands", [46] = "Burning Steppes", [47] = "The Hinterlands",
    [51] = "Searing Gorge", [85] = "Tirisfal Glades", [130] = "Silverpine Forest", [139] = "Eastern Plaguelands", [141] = "Teldrassil",
    [148] = "Darkshore", [215] = "Mulgore", [267] = "Hillsbrad Foothills", [331] = "Ashenvale", [357] = "Feralas", [361] = "Felwood",
    [400] = "Thousand Needles", [405] = "Desolace", [406] = "Stonetalon Mountains", [440] = "Tanaris", [490] = "Un'Goro Crater",
    [491] = "Razorfen Kraul", [493] = "Moonglade", [618] = "Winterspring", [717] = "The Stockade", [718] = "Wailing Caverns",
    [719] = "Blackfathom Deeps", [721] = "Gnomeregan", [722] = "Razorfen Downs", [796] = "Scarlet Monastery", [876] = "GM Island",
    [1176] = "Zul'Farrak", [1337] = "Uldaman", [1377] = "Silithus", [1477] = "Sunken Temple", [1497] = "Undercity",
    [1519] = "Stormwind City", [1537] = "Ironforge", [1581] = "The Deadmines", [1583] = "Blackrock Spire", [1584] = "Blackrock Depths",
    [1637] = "Orgrimmar", [1638] = "Thunder Bluff", [1657] = "Darnassus", [1977] = "Zul'Gurub", [2017] = "Stratholme",
    [2057] = "Scholomance", [2100] = "Maraudon", [2159] = "Onyxia's Lair", [2257] = "Deeprun Tram", [2557] = "Dire Maul",
    [2597] = "Alterac Valley", [2677] = "Blackwing Lair", [2717] = "Molten Core", [3277] = "Warsong Gulch", [3358] = "Arathi Basin",
    [3428] = "Temple of Ahn'Qiraj", [3429] = "Ruins of Ahn'Qiraj", [3456] = "Naxxramas",
}
-- .tele name <player> <place>: names from the realm's game_tele table
C.PLACES = {
    { "Stormwind", "Stormwind" }, { "Ironforge", "Ironforge" }, { "Darnassus", "Darnassus" }, { "Orgrimmar", "Orgrimmar" },
    { "Undercity", "Undercity" }, { "ThunderBluff", "Thunder Bluff" }, { "GMIsland", "GM Island" },
}
-- .ban account <account> <duration> "<reason>": duration as the realm reads it (TimeStringToSecs; 0 = for good)
C.BAN_TIMES = { { "1h", "1 hour" }, { "1d", "1 day" }, { "3d", "3 days" }, { "7d", "7 days" }, { "30d", "30 days" }, { "0", "Permanent" } }
C.COMMON = {
    ".gm on", ".gm off", ".gm visible off", ".gm visible on", ".gm ingame", ".gps", ".recall",
    ".whispers off", ".whispers on", ".modify speed 3", ".modify speed 1", ".saveall",
    ".lookup player account ", ".server info",
}

-- -- helpers --------------------------------------------------------------------------------

function C.ZoneName(zone, map)
    local z = C.ZONES[tonumber(zone) or -1]
    if z then return z end
    map = tonumber(map)
    if map == 0 then return "Eastern Kingdoms" elseif map == 1 then return "Kalimdor" end
    return "Map " .. tostring(map or "?")
end

function C.ClassName(id) return C.CLASSES[tonumber(id) or 0] or "Unknown" end
function C.RaceName(id) return C.RACES[tonumber(id) or 0] or "Unknown" end

-- "203.0.113.7" -> "203.0.x.x"; anything else keeps its first two pieces.
function C.MaskIp(ip)
    ip = ip or ""
    if ip == "" then return "" end
    local _, _, a, b = strfind(ip, "^(%d+)%.(%d+)%.")
    if a then return a .. "." .. b .. ".x.x" end
    local _, _, c, d = strfind(ip, "^([^:]*):([^:]*):")
    if c then return c .. ":" .. d .. ":..." end
    return "hidden"
end

function C.Gold(copper)
    copper = floor(tonumber(copper) or 0)
    local g = floor(copper / 10000)
    if g >= 1 then return g .. "|cffffd700g|r" end
    local s = floor(copper / 100)
    return s .. "|cffc7c7cfs|r"
end

-- text that is safe to put in one chat line: no raw '|', no line breaks, trimmed
function C.Clean(t, limit)
    t = gsub(tostring(t or ""), "[%c|]", " ")
    t = W.Trim(t)
    if limit and strlen(t) > limit then t = strsub(t, 1, limit) end
    return t
end

local function validName(name)
    return name and name ~= "" and not strfind(name, "[%s%c|,;%.]")
end
C.ValidName = validName

-- account names may carry dots, dashes and underscores; never spaces, quotes or separators
local function validAccount(acc)
    return acc and acc ~= "" and not strfind(acc, "[%s%c|,;\"]")
end

-- -- the server feed ------------------------------------------------------------------------

function C:Ask(what) return W:SendCommand("gm", what) end

local FIELDS = { "name", "level", "race", "class", "gender", "zone", "map", "x", "y", "z", "hp", "maxhp", "power",
    "maxpower", "powerType", "copper", "account", "accountLevel", "mutedSec", "state", "combat", "latency", "gmOn" }
local TEXT = { name = true, account = true }

function C.ParseRoster(body)
    local list = {}
    if not body or body == "" then return list end
    for _, row in ipairs(W.Split(body, ";")) do
        if row ~= "" then
            local f, n = W.Split(row, ",")
            if n >= 25 and f[1] ~= "" then
                local p = {}
                for i, k in ipairs(FIELDS) do
                    if TEXT[k] then p[k] = f[i] else p[k] = tonumber(f[i]) or 0 end
                end
                p.guild = table.concat(f, ",", 24, n - 1)
                p.ip = f[n]
                p.className = C.ClassName(p.class)
                p.raceName = C.RaceName(p.race)
                p.zoneName = C.ZoneName(p.zone, p.map)
                p.frac = (p.maxhp > 0) and (p.hp / p.maxhp) or 0
                table.insert(list, p)
            end
        end
    end
    -- the same address on more than one character
    local byIp = {}
    for _, p in ipairs(list) do
        if p.ip ~= "" then
            byIp[p.ip] = byIp[p.ip] or {}
            table.insert(byIp[p.ip], p.name)
        end
    end
    for _, p in ipairs(list) do
        local same = byIp[p.ip]
        if same and getn(same) > 1 then
            p.sameIp = {}
            for _, n2 in ipairs(same) do if n2 ~= p.name then table.insert(p.sameIp, n2) end end
        end
    end
    return list
end

function C.ParseBugs(body)
    local list = {}
    if not body or body == "" then return list end
    for _, row in ipairs(W.Split(body, ";")) do
        local f, n = W.Split(row, ",")
        if n >= 12 and tonumber(f[1]) then
            table.insert(list, {
                id = tonumber(f[1]), created = tonumber(f[2]) or 0, name = f[3], level = tonumber(f[4]) or 0,
                class = tonumber(f[5]) or 0, map = tonumber(f[6]) or 0, zone = tonumber(f[7]) or 0,
                x = tonumber(f[8]) or 0, y = tonumber(f[9]) or 0, z = tonumber(f[10]) or 0,
                category = f[11], text = table.concat(f, ",", 12, n),
            })
        end
    end
    table.sort(list, function(a, b) return a.id > b.id end)
    return list
end

-- flags shown in the roster, most serious first
function C.Flags(p)
    local out = {}
    if p.gmOn == 1 then table.insert(out, "|cff40c0ffGM|r") end
    if p.mutedSec > 0 then table.insert(out, "|cffff6060Muted|r") end
    if p.state == 1 then table.insert(out, "|cff9d9d9dDead|r") elseif p.state == 2 then table.insert(out, "|cff9d9d9dGhost|r") end
    if p.sameIp then table.insert(out, "|cffffd100Same IP|r") end
    return table.concat(out, " ")
end

local function flagRank(p)
    return (p.gmOn == 1 and 8 or 0) + (p.mutedSec > 0 and 4 or 0) + (p.state > 0 and 2 or 0) + (p.sameIp and 1 or 0)
end

local SORTERS = {
    name = function(p) return strlower(p.name) end,
    level = function(p) return p.level end,
    class = function(p) return p.className end,
    race = function(p) return p.raceName end,
    zone = function(p) return p.zoneName end,
    hp = function(p) return p.frac end,
    copper = function(p) return p.copper end,
    account = function(p) return strlower(p.account) end,
    latency = function(p) return p.latency end,
    flags = flagRank,
}

function C:SetSort(key)
    if not SORTERS[key] then return end
    if self.sortKey == key then self.sortDesc = not self.sortDesc
    else self.sortKey, self.sortDesc = key, (key ~= "name" and key ~= "account" and key ~= "class" and key ~= "race" and key ~= "zone") end
    if self.Render then self:Render() end
end

function C:SetFilter(text)
    self.filter = strlower(W.Trim(text or ""))
    if self.Render then self:Render() end
end

local function matches(p, f)
    if f == "" then return true end
    for _, hay in ipairs({ p.name, p.account, p.guild, p.zoneName, p.className, p.raceName }) do
        if strfind(strlower(hay or ""), f, 1, true) then return true end
    end
    return false
end

-- the roster as the Players tab shows it: filtered, then sorted
function C:View()
    local out = {}
    for _, p in ipairs(self.roster) do
        if matches(p, self.filter) then table.insert(out, p) end
    end
    local key, desc = SORTERS[self.sortKey] or SORTERS.name, self.sortDesc
    table.sort(out, function(a, b)
        local x, y = key(a), key(b)
        if x == y then return strlower(a.name) < strlower(b.name) end
        if desc then return x > y end
        return x < y
    end)
    return out
end

function C:OnRoster(body)
    self.roster = C.ParseRoster(body)
    self.byName = {}
    for _, p in ipairs(self.roster) do self.byName[p.name] = p end
    self.rosterAt = GetTime and GetTime() or 0
    if self.Render then self:Render() end
end

function C:OnBugs(body)
    self.bugs = C.ParseBugs(body)
    if self.RenderBugs then self:RenderBugs() end
end

function C:OnHello(body)
    local _, _, lvl = strfind(body or "", "^OK%s*(%d*)")
    if not lvl then return end
    self.gm = true
    self.level = tonumber(lvl) or 1
    if self.wantOpen then
        self.wantOpen = false
        self:Open()
    end
end

W:RegisterModule("GM", function(body) C:OnHello(body) end)
W:RegisterModule("GR", function(body) if C.gm then C:OnRoster(body) end end)
W:RegisterModule("GB", function(body) if C.gm then C:OnBugs(body) end end)

-- -- output strip: the realm's answers to GM commands ---------------------------------------

function C:Echo(line)
    table.insert(self.out, line)
    while getn(self.out) > self.MAX_OUT do table.remove(self.out, 1) end
    if self.RenderOut then self:RenderOut() end
end

-- -- commands -------------------------------------------------------------------------------

-- Run one GM chat command (".kick Name"), exactly as if typed.
function C:Run(cmd)
    cmd = C.Clean(cmd, 255)
    if strsub(cmd, 1, 1) ~= "." or strlen(cmd) < 2 then return false end
    SendChatMessage(cmd, "SAY")
    self:Echo("|cff9aa0aa> " .. cmd .. "|r")
    return true
end

StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs["OVCONSOLE_CONFIRM"] = {
    text = "%s",
    button1 = YES or "Yes",
    button2 = CANCEL or "Cancel",
    OnAccept = function()
        local fn = C.pending
        C.pending = nil
        if fn then fn() end
    end,
    OnCancel = function() C.pending = nil end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

function C:Confirm(text, fn)
    self.pending = fn
    StaticPopup_Show("OVCONSOLE_CONFIRM", text)
end

-- Actions on one player. Each returns false (and runs nothing) for a missing or odd name.
C.Act = {}
local A = C.Act

function A.whisper(name, text)
    text = C.Clean(text, 240)
    if not validName(name) or text == "" then return false end
    SendChatMessage(text, "WHISPER", nil, name)
    C:Echo("|cffff80ffTo " .. name .. ": " .. text .. "|r")
    return true
end
function A.appear(name) return validName(name) and C:Run(".appear " .. name) end
function A.summon(name) return validName(name) and C:Run(".summon " .. name) end
function A.revive(name) return validName(name) and C:Run(".revive " .. name) end
function A.pinfo(name) return validName(name) and C:Run(".pinfo " .. name) end
function A.unmute(name) return validName(name) and C:Run(".unmute " .. name) end
function A.tele(name, place)
    local ok = false
    for _, p in ipairs(C.PLACES) do if p[1] == place then ok = true end end
    return ok and validName(name) and C:Run(".tele name " .. name .. " " .. place)
end
local function minutes(m)
    m = floor(tonumber(m) or 0)
    if m < 1 then m = 10 end
    if m > 10080 then m = 10080 end
    return m
end
C.Minutes = minutes
function A.mute(name, m) return validName(name) and C:Run(".mute " .. name .. " " .. minutes(m)) end
function A.kick(name)
    if not validName(name) then return false end
    C:Confirm("Kick " .. name .. " off the realm?", function() C:Run(".kick " .. name) end)
    return true
end
function A.resetTalents(name)
    if not validName(name) then return false end
    C:Confirm("Reset " .. name .. "'s talents? Their points come back to spend again.", function() C:Run(".reset talents " .. name) end)
    return true
end
function A.jail(name, m)
    if not validName(name) then return false end
    m = minutes(m)
    C:Confirm("Jail " .. name .. "? They go to GM Island and are muted for " .. m .. " minutes.", function()
        C:Run(".tele name " .. name .. " GMIsland")
        C:Run(".mute " .. name .. " " .. m)
    end)
    return true
end
function A.ban(account, duration, reason)
    reason = gsub(C.Clean(reason, 120), "\"", "'")
    if not validAccount(account) or reason == "" then return false end
    local label = duration
    for _, d in ipairs(C.BAN_TIMES) do if d[1] == duration then label = d[2] end end
    if label == duration then return false end
    C:Confirm("Ban the account " .. account .. " (" .. string.lower(label) .. ")?\nReason: " .. reason, function()
        C:Run(".ban account " .. account .. " " .. duration .. " \"" .. reason .. "\"")
    end)
    return true
end
function A.announce(text)
    text = C.Clean(text, 200)
    return text ~= "" and C:Run(".announce " .. text)
end
function A.notify(text)
    text = C.Clean(text, 200)
    return text ~= "" and C:Run(".notify " .. text)
end
function A.go(bug)
    if not bug then return false end
    return C:Run(format and format(".go xyz %.1f %.1f %.1f %d", bug.x, bug.y, bug.z, bug.map)
        or (".go xyz " .. bug.x .. " " .. bug.y .. " " .. bug.z .. " " .. bug.map))
end

-- the free command box: remembered for the up arrow and the recent list
function C:RunTyped(text)
    text = C.Clean(text, 255)
    if text == "" then return false end
    if strsub(text, 1, 1) ~= "." then text = "." .. text end
    if not self:Run(text) then return false end
    if self.history[getn(self.history)] ~= text then table.insert(self.history, text) end
    while getn(self.history) > 30 do table.remove(self.history, 1) end
    return true
end

-- -- the window's lifecycle (Window.lua builds it) ------------------------------------------

function C:Open()
    if not self.gm then return end
    local f = self:Build()
    f:Show()
    self:Ask("roster")
    self.sinceAsk = 0
end

function C:Toggle()
    if not self.gm then return end
    local f = self:Build()
    if f:IsShown() then f:Hide() else self:Open() end
end

function C:Command()
    if self.gm then
        self:Toggle()
    else
        self.wantOpen = true
        self:Ask("hi")
    end
end

-- -- events -----------------------------------------------------------------------------------

local ev = CreateFrame("Frame", "OVConsole_Events")
ev:RegisterEvent("CHAT_MSG_SYSTEM")
ev:RegisterEvent("UNIT_INVENTORY_CHANGED")
ev:SetScript("OnEvent", function()
    if event == "CHAT_MSG_SYSTEM" then
        if not C.gm then return end
        local msg = arg1 or ""
        local head = strsub(msg, 1, 4)
        if head == "WNL\t" or head == "WNL " then return end
        C:Echo(msg)
    elseif event == "UNIT_INVENTORY_CHANGED" then
        if C.gm and arg1 == "target" and C.ReadGear then C:ReadGear() end
    end
end)

-- -- the secret command -----------------------------------------------------------------------
-- Registering it is what keeps a player's /ovgm silent (an unknown slash command prints help).

SLASH_OVCONSOLE1 = "/ovgm"
SLASH_OVCONSOLE2 = "/gmc"
SlashCmdList["OVCONSOLE"] = function() C:Command() end
