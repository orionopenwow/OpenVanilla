-- The in-game Herald addon against a small mock of the 1.12 API:  lua5.1 tests/addon_herald_test.lua
-- Checks what it SAYS to the server (.bot self, .bot cmd <me> nc ...) and how it reads the replies.

local said, chat, frames, strings = {}, {}, {}, {}
local now, xp, xpmax, money = 100, 50, 400, 1000

local function obj()
  local o = { scripts = {}, shown = false, events = {} }
  local mt = {}
  mt.__index = function(t, k)
    if k == "SetScript" then return function(self, n, fn) self.scripts[n] = fn end end
    if k == "RegisterEvent" then return function(self, e) self.events[e] = true end end
    if k == "Show" then return function(self) self.shown = true end end
    if k == "Hide" then return function(self) self.shown = false end end
    if k == "IsShown" then return function(self) return self.shown end end
    if k == "SetText" then return function(self, s) self.text = s end end
    if k == "GetText" then return function(self) return self.text end end
    if k == "CreateFontString" or k == "CreateTexture" then
      return function() local fs = obj(); table.insert(strings, fs); return fs end
    end
    if k == "LockHighlight" then return function(self) self.lit = true end end
    if k == "UnlockHighlight" then return function(self) self.lit = false end end
    if string.find(k, "^%u") then return function() end end
    return nil
  end
  return setmetatable(o, mt)
end

function CreateFrame(kind, name)
  local o = obj()
  if name then _G[name] = o end
  table.insert(frames, o)
  return o
end
UIParent, Minimap, GameTooltip = obj(), obj(), obj()
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(chat, m) end }
function SendChatMessage(m, kind) table.insert(said, m) end
function UnitName() return "Thrallson" end
function UnitXP() return xp end
function UnitXPMax() return xpmax end
function GetMoney() return money end
function GetTime() return now end
local mapx, mapy, fighting = 0.40, 0.60, false
function GetPlayerMapPosition() return mapx, mapy end
function UnitAffectingCombat() return fighting end
function UnitIsDeadOrGhost() return false end
SlashCmdList = {}

dofile("Data/Interface/addons/Herald/Herald.lua")

local function fire(e, a1)
  for _, fr in ipairs(frames) do
    if fr.events[e] and fr.scripts.OnEvent then
      event, arg1 = e, a1
      this = fr
      fr.scripts.OnEvent()
    end
  end
end
local function update(dt)
  for _, fr in ipairs(frames) do
    if fr.scripts.OnUpdate then arg1 = dt; this = fr; fr.scripts.OnUpdate() end
  end
end
local fails = 0
local function check(c, m) if not c then fails = fails + 1; print("FAIL: " .. m) end end
local function last() return said[#said] end

fire("VARIABLES_LOADED")
fire("PLAYER_ENTERING_WORLD")
SlashCmdList.HERALD("")
check(HeraldPanel:IsShown(), "/herald opens the panel")
check(HeraldPlayButton.text == "Let Herald play", "button offers to play")

-- hand over
HeraldPlayButton.scripts.OnClick()
check(last() == ".bot self", "START says .bot self")
fire("CHAT_MSG_SYSTEM", "Enable player ai")
check(HeraldPlayButton.text == "Take back control", "button flips once the realm agrees")
update(1.0); check(last() == ".bot self", "waits before the first order")
update(1.0); check(last() == ".bot cmd Thrallson nc +grind,+rpg,+rpg quest,+travel,+loot,+food,+quest,-rpg vendor,-rpg bank,-rpg guild,-rpg craft,-rpg bg,-rpg player,-maintenance,-guild,-pvp,-bg,-arena,-lfg,-duel,-start duel,-ads,-ai chat,-say,-emote", "level-up strategies sent: " .. tostring(last()))

-- change the goal while playing
HeraldGoal2.scripts.OnClick()
check(last() == ".bot cmd Thrallson nc +rpg,+rpg quest,+quest,+travel,+loot,+food,-grind,-rpg vendor,-rpg bank,-rpg guild,-rpg craft,-rpg bg,-rpg player,-maintenance,-guild,-pvp,-bg,-arena,-lfg,-duel,-start duel,-ads,-ai chat,-say,-emote", "quest goal sent")
check(string.find(last(), "-rpg vendor", 1, true), "never sells, mails or uses the auction house")
check(HeraldGoal2.lit and not HeraldGoal1.lit, "chosen goal highlighted")

-- numbers
xp = 150; fire("PLAYER_XP_UPDATE")
xpmax = 900; xp = 20; fire("PLAYER_XP_UPDATE")        -- a level-up: 250 left over the old bar, then 20
money = 1350; fire("PLAYER_MONEY")
fire("CHAT_MSG_COMBAT_HOSTILE_DEATH", "You have slain Kobold Vermin!")
fire("CHAT_MSG_COMBAT_HOSTILE_DEATH", "Kobold Vermin dies.")
fire("PLAYER_DEAD")
now = now + 125
SlashCmdList.HERALD(""); SlashCmdList.HERALD("")
update(1.1)
local s = ""
for _, fs in ipairs(strings) do if fs.text and string.find(fs.text, "Kills", 1, true) then s = fs.text end end
check(string.find(s, "Kills: 1", 1, true), "kills counted: " .. s)
check(string.find(s, "Deaths: 1", 1, true), "deaths counted")
check(string.find(s, "XP: +370", 1, true), "XP counted across the level: " .. s)
check(string.find(s, "Time: 2:05", 1, true), "time shown")

-- take back
SlashCmdList.HERALD("stop")
check(last() == ".bot self", "stop says .bot self again")
fire("CHAT_MSG_SYSTEM", "Disable player ai")
check(HeraldPlayButton.text == "Let Herald play", "back to the player")

-- Herald Autopilot takes over from outside the game: no order of our own, the panel opens
HeraldPanel:Hide()
local before = #said
fire("CHAT_MSG_SYSTEM", "Enable player ai (Autopilot)")
check(HeraldPlayButton.text == "Take back control", "remote takeover shows Take back control")
check(HeraldPanel:IsShown(), "remote takeover opens the panel")
update(1.0); update(1.0)
check(#said == before, "the app's plan isn't overwritten by the panel's goal")
fire("PLAYER_ENTERING_WORLD")                       -- a loading screen while he plays
check(HeraldPlayButton.text == "Take back control", "still playing after a loading screen")
fire("CHAT_MSG_SYSTEM", "Disable player ai (Autopilot)")
check(HeraldPlayButton.text == "Let Herald play", "Autopilot gave it back")

-- the watchdog: standing still for two minutes gets an unstuck; moving or fighting doesn't
fire("CHAT_MSG_SYSTEM", "Enable player ai")
update(1.0); update(1.0)                               -- the goal goes out
local function stuckSent() for i = 1, #said do if said[i] == ".bot do Thrallson unstuck" then return true end end return false end
for i = 1, 4 do mapx = mapx + 0.01; update(30) end   -- walking: fine
check(not stuckSent(), "no unstuck while he walks")
fighting = true
for i = 1, 6 do update(30) end                        -- a long fight in one spot: fine
check(not stuckSent(), "no unstuck while he fights")
fighting = false
for i = 1, 6 do update(30) end                        -- standing still, nothing going on
check(stuckSent(), "unstuck after two minutes standing still")

-- a realm with self-bot off
SlashCmdList.HERALD("play")
fire("CHAT_MSG_SYSTEM", "You do not have permission to enable player ai")
local warned = false
for _, m in ipairs(chat) do if string.find(m, "SelfBotLevel", 1, true) then warned = true end end
check(warned, "explains a realm with self-bot off")

if fails == 0 then print("Herald addon: all checks passed") else os.exit(1) end
