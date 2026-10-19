-- Forge Link: Vanilla Forge's link to the game (installed by Test & Play, removed with it).
-- /forge asks the server where you stand (.gps) and what your target is (.npc info), and keeps the
-- answer in ForgeLinkDB. The game writes it to disk on /reload or logout; Forge reads it from there.
-- The server only answers a GM: Forge's Test screen can make your Play Solo account one.

ForgeLinkDB = ForgeLinkDB or {}

local listening = 0
local mark

local function say(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cffe2b65aForge:|r " .. text)
end

local function num(s, key)
  local _, _, v = string.find(s, key .. ":%s*([%-%d%.]+)")
  return v and tonumber(v)
end

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_SYSTEM")
f:SetScript("OnEvent", function()
  if listening <= 0 or not mark then return end
  local m = arg1 or ""
  local map = num(m, "Map")
  if map then mark.map = map end
  local x, y, z = num(m, "X"), num(m, "Y"), num(m, "Z")
  if x and y and z then
    mark.x, mark.y, mark.z = x, y, z
    mark.o = num(m, "Orientation") or 0
  end
  local entry = num(m, "Entry")
  if entry then mark.entry = entry end
  local guid = num(m, "GUID") or num(m, "Guid") or num(m, "guid")
  if guid then mark.guid = guid end
  if mark.x and (mark.entry or not mark.target) and not mark.told then
    mark.told = 1
    ForgeLinkDB.mark = mark
    say(string.format("marked %.1f, %.1f, %.1f%s. Type /reload to send it to Forge.", mark.x, mark.y, mark.z,
      mark.target and (" and " .. mark.target) or ""))
  end
end)

SLASH_FORGELINK1 = "/forge"
SlashCmdList["FORGELINK"] = function(msg)
  if msg == "help" then
    say("/forge marks where you stand (and your target) for Forge. Then /reload.")
    return
  end
  local npc = UnitExists("target") and not UnitIsPlayer("target")
  mark = { char = UnitName("player"), time = time(), zone = GetRealZoneText() }
  if npc then mark.target = UnitName("target") end
  listening = 1
  SendChatMessage(".gps", "SAY")
  if npc then SendChatMessage(".npc info", "SAY") end
  -- no answer means the account isn't a GM yet
  local waited = 0
  f:SetScript("OnUpdate", function()
    waited = waited + arg1
    if waited > 3 then
      f:SetScript("OnUpdate", nil)
      listening = 0
      if not mark.x then
        say("the server didn't answer: on Forge's Test screen, press 'Make me a GM'.")
      elseif not mark.told then
        mark.told = 1
        ForgeLinkDB.mark = mark
        say(string.format("marked %.1f, %.1f, %.1f. Type /reload to send it to Forge.", mark.x, mark.y, mark.z))
      end
    end
  end)
end
