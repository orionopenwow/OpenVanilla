-- Persona protocol test: two simulated 1.12 clients on one chat channel, through a server that trims
-- and collapses spaces. Run:  lua5.1 tools/tests/persona_sim.lua Data/Interface/AddOns/Persona/Persona.lua
-- Two simulated 1.12 clients sharing one chat channel, through a server that trims and collapses spaces.
local SRC = arg[1]
local chunk = assert(loadfile(SRC))
math.mod = math.mod or math.fmod
string.gfind = string.gfind or string.gmatch

local channelLog = {}
local clients = {}

local function newObj(kind, name, env)
  local o = { _kind = kind, _scripts = {}, _shown = true, _text = "", _name = name }
  local mt = {}
  mt.__index = function(t, k)
    return function() return nil end
  end
  setmetatable(o, mt)
  function o:SetScript(k, f) self._scripts[k] = f end
  function o:GetScript(k) return self._scripts[k] end
  function o:Show() self._shown = true end
  function o:Hide() self._shown = false; if self._scripts.OnHide then env.this = self; self._scripts.OnHide() end end
  function o:IsShown() return self._shown end
  function o:IsVisible() return self._shown end
  function o:SetText(t) self._text = t or "" end
  function o:GetText() return self._text end
  function o:GetHeight() return 10 end
  function o:GetFrameLevel() return 1 end
  function o:GetCenter() return 0, 0 end
  function o:GetEffectiveScale() return 1 end
  function o:CreateFontString() return newObj("FontString", nil, env) end
  function o:CreateTexture() local t = newObj("Texture", nil, env); function t:SetTexture(p) self._tex = p; return p and type(p)=="string" and not string.find(p, "Persona_") and not string.find(p,"Parchment") and 1 or nil end; return t end
  function o:AddLine(t) table.insert(self._lines, t) end
  o._lines = {}
  return o
end

local function newClient(name)
  local env = setmetatable({}, { __index = _G })
  env._G = env
  local c = { name = name, env = env, chat = {} }
  env.time = function() return 1000000 end
  env.GetTime = function() return c.clock or 0 end
  env.GetRealmName = function() return "Open Vanilla" end
  env.UnitName = function(u) if u == "player" then return name end return c.units[u] end
  env.UnitIsPlayer = function(u) return c.units[u] and 1 or nil end
  env.UnitExists = function(u) return c.units[u] and 1 or nil end
  env.GetNumIgnores = function() return 0 end
  env.GetChannelName = function(n) if c.joined then return 5 end return 0 end
  env.JoinChannelByName = function(n) c.joined = true end
  env.SendChatMessage = function(msg, kind, lang, id)
    assert(string.len(msg) <= 255, "line too long " .. string.len(msg))
    -- server: collapse space runs, trim
    msg = string.gsub(msg, "  +", " "); msg = string.gsub(msg, "^ +", ""); msg = string.gsub(msg, " +$", "")
    for _, o in ipairs(clients) do
      table.insert(o.queue, { msg, name })
    end
    table.insert(channelLog, name .. ": " .. msg)
  end
  env.CreateFrame = function(kind, fname, parent, tmpl)
    local o = newObj(kind, fname, env)
    if fname then env[fname] = o end
    return o
  end
  env.UIParent = newObj("Frame", "UIParent", env)
  env.Minimap = newObj("Frame", "Minimap", env)
  env.TargetFrame = newObj("Frame", "TargetFrame", env)
  env.TargetPortrait = newObj("Texture", "TargetPortrait", env)
  env.GameTooltip = newObj("GameTooltip", "GameTooltip", env)
  env.GameTooltip.SetUnit = function(self) self._lines = {} end
  env.GameTooltipTextLeft1 = newObj("FontString", nil, env)
  env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(c.chat, m) end }
  env.UISpecialFrames = {}
  env.GameFontHighlightSmall = {}
  env.ChatFrame_OnEvent = function(e) c.chatEvents = (c.chatEvents or 0) + 1 end
  env.UnitPopupButtons = {}; env.UnitPopupMenus = { PLAYER = { "WHISPER", "CANCEL" } }
  env.UnitPopup_OnClick = function() end
  env.ScrollingEdit_OnCursorChanged = function() end
  env.ScrollingEdit_OnUpdate = function() end
  env.strupper = string.upper; env.SlashCmdList = {}
  env.getglobal = function(n) return env[n] end
  c.units = {}
  c.queue = {}
  setfenv(chunk, env)
  chunk()
  -- events
  local ef = env.PersonaEventFrame
  c.fire = function(ev, ...)
    env.event = ev
    for i = 1, 9 do env["arg" .. i] = arg[i] end
    ef._scripts.OnEvent()
  end
  c.update = function(dt)
    c.clock = (c.clock or 0) + dt
    env.arg1 = dt
    ef._scripts.OnUpdate()
  end
  c.deliver = function()
    local q = c.queue; c.queue = {}
    for _, m in ipairs(q) do
      c.fire("CHAT_MSG_CHANNEL", m[1], m[2], "", "5. OWPersona", "", "", 0, 5, "OWPersona")
    end
  end
  table.insert(clients, c)
  return c
end

local A = newClient("Aldric")
local B = newClient("Berra")
for _, c in ipairs(clients) do c.fire("VARIABLES_LOADED"); c.fire("PLAYER_ENTERING_WORLD") end

local function run(sec)
  for i = 1, sec * 10 do
    for _, c in ipairs(clients) do c.update(0.1) end
    for _, c in ipairs(clients) do c.deliver() end
  end
end
run(6)

-- A writes a nasty profile through the real edit window
local P = A.env.Persona
P.ShowEdit()
local e = A.env.PersonaFrame.edit
local bio = "  Leading spaces,  double  spaces, under_scores, pipes |cffff0000red|r, tildes ~~, back\\slashes \\n literal,\nnew line, trailing   "
for i = 1, 20 do bio = bio .. " The quick brown fox " .. i .. " jumps;" end
e.name:SetText("Aldric  Vane")
e.title:SetText("Knight_of ~ the | Rose")
e.pronouns:SetText("he/him"); e.age:SetText("34"); e.home:SetText("Stormwind")
e.bio:SetText(bio)
e.appearance:SetText("Tall.\n\nScar over left eye.")
e.shares:SetText("one\n\ntwo  spaced\nthree")
e.occur:SetText("Back in 10")
e.author:SetText("OOC: Orion")
e.status = "lfrp"; e.exp = "3"; e.crest = "INV_Sword_04"
P.Save()
local mine = P.Mine()
assert(mine.bio == string.sub(bio, 1, 2400), "bio not saved")
run(3)

-- B mouses over A
B.units.mouseover = "Aldric"
B.fire("UPDATE_MOUSEOVER_UNIT")
run(30)
local got = B.env.Persona.Get("Aldric")
assert(got, "B has nothing")
for _, k in ipairs({ "name", "title", "status", "bio", "appearance", "s1", "s2", "s3", "pronouns", "age", "home", "occur", "exp", "crest", "author" }) do
  if (got[k] or "") ~= (mine[k] or "") then
    error("field " .. k .. " differs:\n[" .. tostring(got[k]) .. "]\n[" .. tostring(mine[k]) .. "]")
  end
end
print("round trip OK, rev", got.rev, "lines sent", #channelLog)

-- tooltip shows RP name and lines
B.env.GameTooltip._lines = {}
B.fire("UPDATE_MOUSEOVER_UNIT")
print("tooltip line1:", B.env.GameTooltipTextLeft1:GetText())
for _, l in ipairs(B.env.GameTooltip._lines) do print("  tip:", l) end

-- B views A, the directory, target badge, demo, statuses
B.env.Persona.ShowView("Aldric")
print("view head:", B.env.PersonaFrame.view.head:GetText())
assert(string.find(B.env.PersonaFrame.view.text:GetText(), "||cffff0000red||r", 1, true), "pipes not neutralised")
B.units.target = "Aldric"; B.fire("PLAYER_TARGET_CHANGED")
assert(B.env.PersonaTargetBadge:IsShown(), "badge hidden")
B.env.Persona.ShowList()
print("list info:", B.env.PersonaFrame.list.info:GetText())
B.env.SlashCmdList.PERSONA("demo"); B.env.Persona.RefreshList()
print("list with demo:", B.env.PersonaFrame.list.info:GetText())
B.env.SlashCmdList.PERSONA("st")
B.env.SlashCmdList.PERSONA("help")
B.env.SlashCmdList.PERSONA("")
B.env.Persona.ShowEdit(); B.env.Persona.EditTab("story"); B.env.Persona.EditTab("ooc")
B.env.PersonaMinimapButton._scripts.OnClick()
run(5)
-- A sees B's status change via #P
local bb = A.env.Persona.Get("Berra")
print("A sees Berra status:", bb and bb.status)
-- hidden channel: chat frame filter swallows our channel
A.env.event = "CHAT_MSG_CHANNEL"; A.env.arg9 = "OWPersona"; A.env.ChatFrame_OnEvent("CHAT_MSG_CHANNEL")
A.env.event = "CHAT_MSG_CHANNEL_NOTICE"; A.env.arg9 = "OWPersona"; A.env.ChatFrame_OnEvent("CHAT_MSG_CHANNEL_NOTICE")
A.env.arg9 = "General"; A.env.arg4 = "1. General"; A.env.ChatFrame_OnEvent("CHAT_MSG_CHANNEL")
assert(A.chatEvents == 1, "filter wrong: " .. tostring(A.chatEvents))
-- max line length
local maxl = 0; for _, l in ipairs(channelLog) do maxl = math.max(maxl, #l) end
print("longest line", maxl, " chat msgs to A:", table.concat(A.chat, " | "))
print("ALL OK")
