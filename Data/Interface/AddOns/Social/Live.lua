--[[
    Live.lua  -  the LIVE marks: who on the realm is streaming Open Vanilla right now.

    A player who streams links their channel on the website (openvanilla.app/creators.html), names
    this character and ticks "Show me as LIVE" there; here, in Social's settings, they switch on
    "Show me as LIVE" too (off by default). The fetcher on the realm server sees who is live
    every 5 minutes, Herald hands the names to the world server, and the server sends every
    Classic+ client the online, opted-in ones:

        LV Name;Name;...      or      LV -        (nobody)

    Social shows a red bullet and LIVE next to those names: friends, guild, group, recent and
    /who lists, the Dungeons board and the player tooltip; Persona shows a Live badge.
        /live          who is live right now (and where to watch)

    Client -> server: ".wnl liveopt <0|1>" whenever the suite connects and when the switch changes
    (the server keeps it for the session only, and answers with the current LV list, so every
    client sends it, 0 included).

    Lua 5.0 rules (1.12.1 client): no '#', no '%' operator, handlers read this/event/arg1.
]]--

local W = WenillaCore
local S = Social
local ID = "Social"
local strfind, strsub, strlower, strupper = string.find, string.sub, string.lower, string.upper
local tinsert, getn = table.insert, table.getn

-- The 1.12 fonts have the bullet (Persona uses it); a filled circle is not guaranteed.
local BULLET = "\226\128\162"
S.LIVE_RED = "ffff3b3b"
S.LIVE_TAG = "|c" .. S.LIVE_RED .. BULLET .. " LIVE|r"
S.LIVE_SHORT = "|c" .. S.LIVE_RED .. BULLET .. "|r"
S.WATCH_URL = "openvanilla.app/streamers.html"

S.live = {}        -- name -> true
S.liveList = {}    -- sorted names
S.liveAt = nil     -- time() of the last LV line

local function proper(n)
    return strupper(strsub(n, 1, 1)) .. strlower(strsub(n, 2))
end

-- "A;b;C" -> set and sorted list; anything that is not a plain name is dropped.
function S.ParseLive(body)
    local set, list = {}, {}
    body = body or ""
    if body == "-" then return set, list end
    local pos = 1
    while pos <= string.len(body) do
        local a = strfind(body, ";", pos, true)
        local n = a and strsub(body, pos, a - 1) or strsub(body, pos)
        pos = a and (a + 1) or (string.len(body) + 1)
        if strfind(n, "^[%a\128-\255]+$") and string.len(n) >= 2 and string.len(n) <= 24 then
            n = proper(n)
            if not set[n] then set[n] = true; tinsert(list, n) end
        end
        if getn(list) >= 60 then break end
    end
    table.sort(list)
    return set, list
end

function S:IsLive(name)
    if not name or not W:IsActive(ID) then return false end
    return self.live[name] and true or false
end

-- " • LIVE" after a name (short = just the bullet, for tight columns); "" when not live.
function S:LiveTag(name, short)
    if not self:IsLive(name) then return "" end
    return "  " .. (short and S.LIVE_SHORT or S.LIVE_TAG)
end

function S:OnLive(body)
    local before = table.concat(self.liveList, ";")
    self.live, self.liveList = S.ParseLive(body)
    self.liveAt = time and time() or 0
    if table.concat(self.liveList, ";") == before then return end
    -- everyone who draws names
    if self.Refresh then self:Refresh() end
    if Dungeons and Dungeons.Refresh then pcall(Dungeons.Refresh, Dungeons) end
    if Persona and Persona.RefreshLive then pcall(Persona.RefreshLive) end
end

W:RegisterModule("LV", function(body) S:OnLive(body) end)

-- The tooltip line for a player under the mouse (Persona calls this after it rebuilds the tooltip).
function S.LiveTooltip()
    if not GameTooltip or not UnitIsPlayer or not UnitIsPlayer("mouseover") then return end
    local n = UnitName("mouseover")
    if not S:IsLive(n) then return end
    GameTooltip:AddLine(S.LIVE_TAG .. "|cffffd8d0  streaming now|r")
    GameTooltip:AddLine("Watch: " .. S.WATCH_URL, 0.6, 0.6, 0.65)
    GameTooltip:Show()
end

-- /live -------------------------------------------------------------------------------------------

function S:ListLive()
    if not W.connected then
        W.Print("LIVE marks come from the Classic+ server channel, which isn't connected (/wnl status).")
        return
    end
    local mine = W:Setting(ID, "showLive", false)
    if getn(self.liveList) == 0 then
        W.Print("Nobody on the realm is live right now. Streams and videos: |cffffd100" .. S.WATCH_URL .. "|r")
    else
        local links = {}
        for _, n in ipairs(self.liveList) do
            tinsert(links, "|Hplayer:" .. n .. "|h[" .. n .. "]|h")
        end
        W.Print(S.LIVE_TAG .. " now (" .. getn(self.liveList) .. "): " .. table.concat(links, ", "))
        W.Print("Watch them at |cffffd100" .. S.WATCH_URL .. "|r")
    end
    if not mine then
        W.Print("Streaming yourself? Link your channel at openvanilla.app/creators.html and switch on \"Show me as LIVE\" in Social's settings.")
    end
end

SLASH_OWLIVE1 = "/live"
SlashCmdList["OWLIVE"] = function()
    if not W:IsActive(ID) then W.Print("Social is switched off. Turn it on in /addons.") return end
    S:ListLive()
end

-- Opt-in sync ---------------------------------------------------------------------------------------

local sent = nil      -- what the server last heard from us: nil (nothing), 0 or 1
local acc = 0
local ev = CreateFrame("Frame", "Social_LiveEvents")
ev:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
ev:SetScript("OnEvent", function()
    if event == "UPDATE_MOUSEOVER_UNIT" and not (Persona and Persona.RefreshLive) then S.LiveTooltip() end
end)
ev:SetScript("OnUpdate", function()
    acc = acc + (arg1 or 0)
    if acc < 1 then return end
    acc = 0
    S:SyncLiveOpt()
end)

function S:SyncLiveOpt()
    if not W.connected then sent = nil return end          -- (re)connect: say it again
    local want = (W:IsActive(ID) and W:Setting(ID, "showLive", false)) and 1 or 0
    if want == sent then return end
    if W:SendCommand("liveopt", want) then sent = want end
end

-- for tests: forget what was sent
function S.ResetLiveSync() sent = nil; acc = 0 end
