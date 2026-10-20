--[[
    Core.lua  (Chat)
    The chat window, restyled to match the other addons, with the quality-of-life features players
    usually install chat addons for. The stock ChatFrame1..7, their tabs and ChatFrameEditBox are
    kept (Enter to type, tabs, channels, slash commands, whisper reply and other addons' hooks all
    work as before); this addon only styles them and post-processes the lines they print.

        Core.lua   settings, themes, the line pipeline (timestamps, short channel names, class
                   colours, links, mentions, spam control), the older chat options, /cpchat
        Skin.lua   the look: panel, edge, shadow, tabs, input line, scrollbar, fade, move/resize
        Tools.lua  copy box, link box, whisper tabs, typed history
        World.lua  the World tab (realm-wide chat + Discord [D] lines), channel cycle, /world

    Settings live in WenillaCore_Config.settings.Chat (the Addons window, or right-click a chat
    tab). Turning the addon off puts the stock chat back exactly as it was.
    Lua 5.0 rules (1.12.1): no '#', no '%' operator, handlers read this/event/arg1..
]]--

local W = WenillaCore
CPChat = CPChat or {}
local C = CPChat
local ID = "Chat"
C.ID = ID

local strfind, strsub, strlen, strlower, strupper = string.find, string.sub, string.len, string.lower, string.upper
local gsub, format, floor = string.gsub, string.format, math.floor

-- -- Themes ------------------------------------------------------------------------------------
-- Art comes from tools/gen_chat_art.py: Chat_Panel<suffix>, Chat_Tab<suffix>, Chat_Edge<suffix>.
-- The colours are the flat fallbacks (and the tint of text, tabs and the input line).

C.THEME_ORDER = { "slate", "parchment", "midnight", "wildwood", "glass" }
C.THEMES = {
    slate = {
        label = "Slate", suffix = "",
        face = { 0.105, 0.112, 0.13 }, inset = { 0.05, 0.055, 0.066 }, tab = { 0.085, 0.09, 0.105 },
        edge = { 0.27, 0.29, 0.34 }, top = { 0.56, 0.58, 0.64 }, accent = { 1, 0.82, 0 },
        text = { 0.93, 0.93, 0.95 }, muted = { 0.60, 0.62, 0.68 }, stamp = "8a909c",
        flags = "OUTLINE", edgeSize = 8, edgeOut = 2, shadow = true, topLine = true,
    },
    parchment = {
        label = "Parchment", suffix = "_Parchment",
        face = { 0.78, 0.66, 0.47 }, inset = { 0.68, 0.56, 0.38 }, tab = { 0.70, 0.58, 0.40 },
        edge = { 0.40, 0.27, 0.14 }, top = { 0.96, 0.90, 0.74 }, accent = { 0.62, 0.16, 0.10 },
        text = { 0.20, 0.12, 0.06 }, muted = { 0.36, 0.26, 0.16 }, stamp = "6b5236",
        flags = "", ink = true, edgeSize = 12, edgeOut = 3, shadow = true,
    },
    midnight = {
        label = "Midnight", suffix = "_Midnight",
        face = { 0.035, 0.05, 0.09 }, inset = { 0.02, 0.03, 0.06 }, tab = { 0.03, 0.04, 0.075 },
        edge = { 0.20, 0.27, 0.42 }, top = { 0.46, 0.60, 0.88 }, accent = { 0.55, 0.80, 1 },
        text = { 0.90, 0.93, 1 }, muted = { 0.52, 0.58, 0.72 }, stamp = "6f82a8",
        flags = "OUTLINE", edgeSize = 8, edgeOut = 2, shadow = true, topLine = true,
    },
    wildwood = {
        label = "Wildwood", suffix = "_Wildwood",
        face = { 0.10, 0.095, 0.065 }, inset = { 0.055, 0.05, 0.035 }, tab = { 0.20, 0.15, 0.09 },
        edge = { 0.38, 0.30, 0.19 }, top = { 0.62, 0.52, 0.34 }, accent = { 0.59, 1, 0.67 },
        text = { 0.95, 0.92, 0.85 }, muted = { 0.68, 0.64, 0.54 }, stamp = "8f8a6c",
        flags = "OUTLINE", edgeSize = 14, edgeOut = 6, shadow = true,
    },
    glass = {
        label = "Glass", suffix = "_Glass",
        face = { 0, 0, 0 }, faceAlpha = 0.45, inset = { 0, 0, 0 }, tab = { 0, 0, 0 },
        edge = { 1, 1, 1 }, edgeAlpha = 0.14, top = { 1, 1, 1 }, accent = { 1, 0.82, 0 },
        text = { 0.96, 0.96, 0.96 }, muted = { 0.76, 0.76, 0.80 }, stamp = "a0a0a8",
        flags = "OUTLINE", edgeSize = 6, edgeOut = 1, shadow = false, topLine = true,
    },
}

-- -- Settings ----------------------------------------------------------------------------------

C.DEFAULTS = {
    enabled = true,
    theme = "slate", opacity = 85, fontSize = 13,
    timestamps = "24", channelNames = "short", fade = "20",
    classColors = true, links = true, collapse = true, goldFilter = false,
    whisperTabs = false, mentions = true, mentionSound = true, typedHistory = true,
    wheel = true, arrows = true, sticky = true, history = true, alerts = true,
    worldTab = true, discord = true, worldJoin = true,
}

local function choices(list)
    local out = {}
    for _, c in ipairs(list) do table.insert(out, { value = c[1], label = c[2] }) end
    return out
end

local themeChoices = {}
for _, k in ipairs(C.THEME_ORDER) do table.insert(themeChoices, { k, C.THEMES[k].label }) end

C.SCHEMA = {
    title = "Chat",
    desc = "A sleek, readable chat window that matches the other addons. It works as before: Enter to type, the same tabs, channels and slash commands.",
    icon = "Interface\\Icons\\INV_Scroll_03",
    defaults = C.DEFAULTS,
    options = {
        { key = "theme", label = "Theme", type = "choice", choices = choices(themeChoices) },
        { key = "opacity", label = "Background opacity", type = "slider", min = 40, max = 100, step = 5, fmt = "%d%%" },
        { key = "fontSize", label = "Text size", type = "slider", min = 10, max = 18, step = 1, fmt = "%d pt" },
        { key = "timestamps", label = "Timestamps", type = "choice",
          choices = choices({ { "off", "Off" }, { "24", "24-hour" }, { "12", "12-hour" } }) },
        { key = "channelNames", label = "Channel names", type = "choice",
          choices = choices({ { "short", "Short ([G], [T])" }, { "full", "Full names" } }) },
        { key = "fade", label = "Fade when quiet", type = "choice",
          choices = choices({ { "20", "After 20 s" }, { "60", "After a minute" }, { "never", "Never" } }) },
        { key = "classColors", label = "Class-coloured names", sub = "Names take their class colour once you have seen the player (group, guild, friends, target, /who)." },
        { key = "links", label = "Clickable web links", sub = "Web addresses in chat become links that open a box you can copy them from." },
        { key = "collapse", label = "Collapse repeats", sub = "The same line said again shows as \"\195\1512\", \"\195\1513\" instead of filling the window." },
        { key = "goldFilter", label = "Hide gold sellers", sub = "Hides channel and whisper adverts for gold and power-levelling websites." },
        { key = "mentions", label = "Highlight my name", sub = "Lines that mention you stand out. Turn it off for one tab from the tab bar menu." },
        { key = "mentionSound", label = "Sound when mentioned", sub = "A soft ping, at most once every few seconds." },
        { key = "whisperTabs", label = "Whisper tabs", sub = "Each whisper conversation gets its own tab. Right-click one to close it." },
        { key = "typedHistory", label = "Remember what I typed", sub = "Up and down arrows bring back lines you sent, even after a reload." },
        { key = "wheel", label = "Scroll with the mouse wheel", sub = "Hold Shift to jump to the top or bottom." },
        { key = "arrows", label = "Arrow keys without Alt", sub = "Move the cursor in the chat box with the arrow keys alone." },
        { key = "sticky", label = "Sticky channels", sub = "Whispers, officer, raid and numbered channels stay selected for the next line." },
        { key = "history", label = "Keep 1,000 lines", sub = "A longer scroll-back in every chat tab." },
        { key = "alerts", label = "Guild log-on alerts", sub = "Say when guild members log on and off." },
        { key = "worldTab", label = "World tab", sub = "Realm-wide World chat (both factions) in a tab of its own. Right-click the tab for its menu (Hide this tab is there)." },
        { key = "discord", label = "Show Discord messages", sub = "Lines from the realm's Discord #world, marked [D]." },
        { key = "worldJoin", label = "Join World chat", sub = "Be in the World channel on every character. Off leaves it (and stays off)." },
    },
}

function C:Get(key)
    local v = W:Setting(ID, key)
    if v == nil then return self.DEFAULTS[key] end
    return v
end

function C:SetOption(key, value)
    local s = W:Settings(ID)
    s[key] = value
    if W.Refresh then W:Refresh(ID) end
end

function C:Theme()
    return self.THEMES[self:Get("theme")] or self.THEMES.slate, (self.THEMES[self:Get("theme")] and self:Get("theme")) or "slate"
end

-- The older on/off names (/cpchat, the tab menu), kept so macros and notes still work.
C.OPTIONS = {
    { key = "wheel",      label = "Scroll chat with the mouse wheel" },
    { key = "arrows",     label = "Arrow keys without Alt" },
    { key = "sticky",     label = "Sticky whisper, officer, raid and channels" },
    { key = "history",    label = "Keep 1,000 lines of history" },
    { key = "timestamps", label = "Timestamps" },
    { key = "alerts",     label = "Guild member log-on alerts" },
}

function C:On(key)
    if key == "timestamps" then return self:Get("timestamps") ~= "off" end
    return self:Get(key) and true or false
end

function C:Set(key, on)
    if key == "timestamps" then
        local cur = self:Get("timestamps")
        if on then self:SetOption("timestamps", (cur ~= "off" and cur) or "24") else self:SetOption("timestamps", "off") end
        return
    end
    self:SetOption(key, on and true or false)
end

-- Settings from before 1.15 (ClassicPlus_Defaults.chat, written by WenillaCore's old Chat.lua).
function C:Migrate()
    local s = W:Settings(ID)
    if s.migrated then return end
    s.migrated = true
    local old = type(ClassicPlus_Defaults) == "table" and ClassicPlus_Defaults.chat
    if type(old) ~= "table" then return end
    for _, k in ipairs({ "wheel", "arrows", "sticky", "history", "alerts" }) do
        if old[k] == false then s[k] = false end
    end
    if old.timestamps == false then s.timestamps = "off" end
end

-- Account-wide memory: the class of names seen in chat, for class-coloured names.
local function store()
    if type(ClassicPlus_Chat) ~= "table" then ClassicPlus_Chat = {} end
    if type(ClassicPlus_Chat.classes) ~= "table" then ClassicPlus_Chat.classes = {} end
    return ClassicPlus_Chat
end
C.store = store

-- -- Class colours -----------------------------------------------------------------------------

C.classCount = 0
function C:Learn(name, class)
    if not name or name == "" or not class or class == "" then return end
    local token = strupper(class)
    token = gsub(token, " ", "")
    local t = store().classes
    if t[name] ~= token then
        if not t[name] then
            self.classCount = self.classCount + 1
            if self.classCount > 1500 then store().classes = {}; t = store().classes; self.classCount = 0 end
        end
        t[name] = token
    end
end

function C:LearnUnit(unit)
    if not UnitExists or not UnitExists(unit) then return end
    if UnitIsPlayer and not UnitIsPlayer(unit) then return end
    local _, token = UnitClass(unit)
    self:Learn(UnitName(unit), token)
end

function C:ClassOf(name)
    return name and store().classes[name]
end

local function hex(r, g, b)
    return format("%02x%02x%02x", floor((r or 1) * 255 + 0.5), floor((g or 1) * 255 + 0.5), floor((b or 1) * 255 + 0.5))
end
C.Hex = hex

function C:ClassHex(token)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token or ""]
    if c then return hex(c.r, c.g, c.b) end
    local UI = W.UI
    if UI and UI.CLASS_COLORS and UI.CLASS_COLORS[token or ""] then
        local u = UI.CLASS_COLORS[token]
        return hex(u[1], u[2], u[3])
    end
end

-- -- Text helpers ------------------------------------------------------------------------------

-- Pattern-escape a literal.
local function esc(s)
    return (gsub(s, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end
C.Escape = esc

-- Apply fn to the parts of text that are not inside a |H...|h...|h link.
local function plainMap(text, fn)
    local out, pos = {}, 1
    while true do
        local s, e = strfind(text, "|H.-|h.-|h", pos)
        if not s then
            table.insert(out, fn(strsub(text, pos)))
            break
        end
        table.insert(out, fn(strsub(text, pos, s - 1)))
        table.insert(out, strsub(text, s, e))
        pos = e + 1
    end
    return table.concat(out)
end
C.PlainMap = plainMap

-- Colour codes and links removed: what a player would select and copy.
function C.Strip(text)
    text = text or ""
    text = gsub(text, "|H[^|]*|h(.-)|h", "%1")
    text = gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = gsub(text, "|r", "")
    text = gsub(text, "|T[^|]*|t", "")
    return text
end

-- [2. Trade - City] -> [T], [Guild] -> [G] ... (only at the start of a line)
local GROUP_SHORT = {
    { "[Guild]", "[G]" }, { "[Officer]", "[O]" }, { "[Party]", "[P]" }, { "[Raid Leader]", "[RL]" },
    { "[Raid Warning]", "[RW]" }, { "[Raid]", "[R]" }, { "[Battleground Leader]", "[BL]" },
    { "[Battleground]", "[BG]" },
}
function C:ShortChannel(text)
    local s, e, num, name = strfind(text, "^%[(%d+)%. ([^%]]-)%]")
    if s then
        local l = strlower(name)
        local label = num
        if strfind(l, "^trade") then label = "T"
        elseif strfind(l, "^lookingforgroup") or strfind(l, "^lfg") then label = "LFG"
        elseif l == "world" then label = "W" end
        return "[" .. label .. "]" .. strsub(text, e + 1)
    end
    for _, p in ipairs(GROUP_SHORT) do
        if strsub(text, 1, strlen(p[1])) == p[1] then return p[2] .. strsub(text, strlen(p[1]) + 1) end
    end
    return text
end

-- The author's name in their class colour: |Hplayer:Name|h[Name]|h, or a plain [Name].
function C:ColourName(text, author)
    local hx = self:ClassHex(self:ClassOf(author))
    if not hx then return text end
    local coloured = "|cff" .. hx .. author .. "|r"
    local s, e = strfind(text, "|Hplayer:" .. esc(author) .. "[^|]*|h%[")
    if s and strsub(text, e + 1, e + strlen(author)) == author then
        return strsub(text, 1, e) .. coloured .. strsub(text, e + 1 + strlen(author))
    end
    s = strfind(text, "[" .. author .. "]", 1, 1)
    if s then
        return strsub(text, 1, s) .. coloured .. strsub(text, s + 1 + strlen(author))
    end
    return text
end

-- Web addresses -> |Hurl:...|h links (opened in the link box by SetItemRef, see Tools.lua).
local TLD = {
    com = 1, net = 1, org = 1, gg = 1, io = 1, co = 1, uk = 1, de = 1, fr = 1, eu = 1, tv = 1,
    info = 1, app = 1, dev = 1, xyz = 1, ru = 1, nl = 1, ly = 1, link = 1, wiki = 1, gl = 1,
}
C.LINK_COLOUR = "6fb6ff"

local function isUrl(tok)
    if strfind(tok, "|") then return false end
    if strfind(tok, "^%a[%w%+%.%-]*://[%w]") then return true end
    if strfind(tok, "^www%.[%w%-]+%.%a") then return true end
    local _, _, host = strfind(tok, "^([%w%-%.]+)")
    if not host or not strfind(host, "%.") then return false end
    local _, _, tld = strfind(host, "%.(%a+)$")
    if not tld or not TLD[strlower(tld)] then return false end
    local _, _, first = strfind(host, "^([%w%-]+)%.")
    return first and strlen(first) >= 2 and strfind(first, "%a") and true or false
end
C.IsUrl = isUrl

function C:Linkify(text)
    if not strfind(text, "[%.:]") then return text end
    return plainMap(text, function(part)
        return (gsub(part, "(%S+)", function(tok)
            local _, _, body, trail = strfind(tok, "^(.-)([%.,;:!%?%)]*)$")
            if body and body ~= "" and isUrl(body) then
                return "|cff" .. C.LINK_COLOUR .. "|Hurl:" .. body .. "|h[" .. body .. "]|h|r" .. (trail or "")
            end
            return tok
        end))
    end)
end

-- Your name in a line someone else wrote. Case-insensitive, whole words only.
local function nameSpots(text, name)
    local spots = {}
    local lt, ln = strlower(text), strlower(name)
    local pos = 1
    while true do
        local s, e = strfind(lt, ln, pos, 1)
        if not s then break end
        local before = s > 1 and strsub(lt, s - 1, s - 1) or ""
        local after = strsub(lt, e + 1, e + 1)
        if not strfind(before, "[%w\128-\255]") and not strfind(after, "[%w\128-\255]") then
            table.insert(spots, { s, e })
        end
        pos = e + 1
    end
    return spots
end

function C:Mentions(msg)
    local me = UnitName and UnitName("player")
    if not me or me == "" or type(msg) ~= "string" then return false end
    return nameSpots(msg, me)[1] ~= nil
end

function C:Highlight(text)
    local me = UnitName("player")
    local hx = hex(1, 0.62, 0.18)
    return plainMap(text, function(part)
        local spots = nameSpots(part, me)
        if not spots[1] then return part end
        local out, pos = {}, 1
        for _, sp in ipairs(spots) do
            table.insert(out, strsub(part, pos, sp[1] - 1))
            table.insert(out, "|cff" .. hx .. strsub(part, sp[1], sp[2]) .. "|r")
            pos = sp[2] + 1
        end
        table.insert(out, strsub(part, pos))
        return table.concat(out)
    end)
end

-- Gold-seller adverts: a web address (www, .com, "dot com"...) together with a selling word.
function C:IsGoldSpam(msg)
    if type(msg) ~= "string" then return false end
    local m = strlower(msg)
    m = gsub(m, "|c%x%x%x%x%x%x%x%x", "")
    m = gsub(m, "[%s%*_,~'\"`]", "")
    m = gsub(m, "0", "o")
    m = gsub(m, "dot", ".")
    m = gsub(m, "%(%.%)", ".")
    m = gsub(m, "%[%.%]", ".")
    local site = strfind(m, "www") or strfind(m, "%.com") or strfind(m, "%.net") or strfind(m, "%.org")
        or strfind(m, "%.cn") or strfind(m, "%.ru") or strfind(m, "http")
    if not site then return false end
    local sell = strfind(m, "gold") or strfind(m, "usd") or strfind(m, "%$") or strfind(m, "eur")
        or strfind(m, "cheap") or strfind(m, "deliver") or strfind(m, "powerlevel") or strfind(m, "lvling")
        or strfind(m, "leveling") or strfind(m, "levelling") or strfind(m, "discount")
    return sell and true or false
end

-- -- Timestamps --------------------------------------------------------------------------------

function C:Stamp()
    local mode = self:Get("timestamps")
    if mode == "off" or not date then return nil end
    if mode == "12" then
        local h = tonumber(date("%I")) or 12
        local ap = (date("%p") == "PM") and "pm" or "am"
        return h .. date(":%M") .. ap
    end
    return date("%H:%M")
end

-- -- Parchment ink: bright game colours turned into dark ink that reads on paper ----------------

function C.InkRGB(r, g, b)
    r, g, b = r or 1, g or 1, b or 1
    local w = math.min(r, math.min(g, b))
    local k = 0.44
    local lift = 0.24
    return math.max(0.03, r * k - w * lift), math.max(0.02, (g * k - w * lift) * 0.84), math.max(0.01, (b * k - w * lift) * 0.62)
end

function C.InkText(text)
    return (gsub(text, "|c(%x%x)(%x%x)(%x%x)(%x%x)", function(a, rr, gg, bb)
        local r, g, b = C.InkRGB(tonumber(rr, 16) / 255, tonumber(gg, 16) / 255, tonumber(bb, 16) / 255)
        return "|c" .. a .. hex(r, g, b)
    end))
end

-- -- The line pipeline -------------------------------------------------------------------------
-- ChatFrame_OnEvent is wrapped so AddMessage knows which chat event (and author) a line is for.
-- Each ChatFrameN.AddMessage is wrapped once and stays wrapped; it passes lines through untouched
-- while the addon is off, so other addons' hooks above or below it keep working.

local PLAYER_EVENTS = {
    CHAT_MSG_SAY = 1, CHAT_MSG_YELL = 1, CHAT_MSG_WHISPER = 1, CHAT_MSG_WHISPER_INFORM = 1,
    CHAT_MSG_CHANNEL = 1, CHAT_MSG_PARTY = 1, CHAT_MSG_RAID = 1, CHAT_MSG_RAID_LEADER = 1,
    CHAT_MSG_RAID_WARNING = 1, CHAT_MSG_GUILD = 1, CHAT_MSG_OFFICER = 1, CHAT_MSG_EMOTE = 1,
    CHAT_MSG_BATTLEGROUND = 1, CHAT_MSG_BATTLEGROUND_LEADER = 1,
}
C.PLAYER_EVENTS = PLAYER_EVENTS
local PUBLIC = { CHAT_MSG_SAY = 1, CHAT_MSG_YELL = 1, CHAT_MSG_WHISPER = 1, CHAT_MSG_CHANNEL = 1, CHAT_MSG_EMOTE = 1 }

C.MAX_BUFFER = 1000
C.filtered = 0
C.mentionAt = -100

local origOnEvent = ChatFrame_OnEvent
if origOnEvent then
    function ChatFrame_OnEvent(ev)
        local pe, pm, pa, pf = C.ctxEvent, C.ctxMsg, C.ctxAuthor, C.ctxFrame
        C.ctxEvent, C.ctxMsg, C.ctxAuthor, C.ctxFrame = ev, arg1, arg2, this
        local r = origOnEvent(ev)
        C.ctxEvent, C.ctxMsg, C.ctxAuthor, C.ctxFrame = pe, pm, pa, pf
        return r
    end
end

local function now() return GetTime and GetTime() or 0 end

-- True when the frame shows its newest line (GetCurrentScroll counts lines up from the bottom).
function C.AtBottom(f)
    if f.GetCurrentScroll then
        local c = f:GetCurrentScroll()
        if c then return c == 0 end
    end
    if f.AtBottom then return f:AtBottom() and true or false end
    return true
end

local function remember(frame, entry)
    local lines = frame.cpLines
    if not lines then lines = {}; frame.cpLines = lines end
    table.insert(lines, entry)
    if table.getn(lines) > C.MAX_BUFFER then table.remove(lines, 1) end
end

-- Print one buffered line (ink applied for the Parchment theme).
function C:Emit(frame, e)
    local add = frame.cpOrigAdd or frame.AddMessage
    if self.active and self.inked then
        local r, g, b = C.InkRGB(e.r, e.g, e.b)
        return add(frame, C.InkText(e.text), r, g, b, e.id)
    end
    return add(frame, e.text, e.r, e.g, e.b, e.id)
end

-- Print the buffer again (theme change, a collapsed repeat). Keeps the newest lines.
function C:Render(frame)
    if not frame.cpLines or not frame.Clear then return end
    frame:Clear()
    for _, e in ipairs(frame.cpLines) do self:Emit(frame, e) end
    self.renders = (self.renders or 0) + 1
end

function C:RenderAll()
    for i = 1, (NUM_CHAT_WINDOWS or 7) do
        local f = getglobal("ChatFrame" .. i)
        if f and f.cpLines then self:Render(f) end
    end
    if self.RenderWhispers then self:RenderWhispers() end
    if self.RenderWorld then self:RenderWorld() end
end

function C:MentionsOn(frame)
    if not self:Get("mentions") then return false end
    local off = W:Settings(ID).mentionOff
    return not (type(off) == "table" and frame and frame.GetName and off[frame:GetName() or ""])
end

function C:Add(frame, orig, msg, r, g, b, id, hold)
    if not self.active or type(msg) ~= "string" then
        if type(msg) == "string" then remember(frame, { text = msg, r = r, g = g, b = b, id = id }) end
        return orig(frame, msg, r, g, b, id, hold)
    end
    local ev, author, raw
    if self.ctxFrame == frame then ev, author, raw = self.ctxEvent, self.ctxAuthor, self.ctxMsg end
    local player = ev and PLAYER_EVENTS[ev]
    local me = UnitName and UnitName("player")
    local mine = author and author == me
    if player and not mine and PUBLIC[ev] and self:Get("goldFilter") and self:IsGoldSpam(raw) then
        self.filtered = self.filtered + 1
        return
    end

    local text = msg
    local mention = false
    if player then
        if self:Get("channelNames") ~= "full" then text = self:ShortChannel(text) end
        if self:Get("classColors") and author and author ~= "" then text = self:ColourName(text, author) end
        if not mine and ev ~= "CHAT_MSG_WHISPER_INFORM" and self:MentionsOn(frame) and self:Mentions(raw) then
            text = self:Highlight(text)
            mention = true
        end
    end
    if self:Get("links") then text = self:Linkify(text) end

    -- whisper tabs take whispers out of the main window
    if player and (ev == "CHAT_MSG_WHISPER" or ev == "CHAT_MSG_WHISPER_INFORM") and self:Get("whisperTabs") and self.RouteWhisper then
        local st = self:Stamp()
        if st then text = "|cff" .. self:Theme().stamp .. st .. "|r " .. text end
        self:RouteWhisper(author, text, r, g, b, ev, raw)
        return
    end

    -- collapse a line said again (same event, author and words) into "x2", "x3"
    if player and self:Get("collapse") then
        local key = ev .. "\1" .. (author or "") .. "\1" .. (raw or msg)
        local lines = frame.cpLines
        local last = lines and lines[table.getn(lines)]
        if last and last.key == key and now() - (last.at or 0) < 120 then
            last.count = (last.count or 1) + 1
            last.at = now()
            last.text = last.base .. " |cff9aa0aa\195\151" .. last.count .. "|r"
            self.collapsed = (self.collapsed or 0) + 1
            if C.AtBottom(frame) then self:Render(frame) end
            self:Touch(frame, mention)
            return
        end
    end

    local st = self:Stamp()
    if st then text = "|cff" .. self:Theme().stamp .. st .. "|r " .. text end
    local entry = { text = text, base = text, r = r, g = g, b = b, id = id }
    if player then entry.key = ev .. "\1" .. (author or "") .. "\1" .. (raw or msg); entry.at = now() end
    remember(frame, entry)
    self:Emit(frame, entry)
    self:Touch(frame, mention)
end

-- A new line woke the window (fade timer) and maybe marks its tab.
function C:Touch(frame, mention)
    self.lastActivity = now()
    if mention then
        frame.cpMention = true
        if self.MarkUnread then self:MarkUnread(frame, true) end
        if self:Get("mentionSound") and now() - self.mentionAt > 4 then
            self.mentionAt = now()
            if PlaySound then PlaySound("MapPing") end
        end
    end
end

function C:HookFrame(f)
    if not f or f.cpOrigAdd or not f.AddMessage then return end
    local orig = f.AddMessage
    f.cpOrigAdd = orig
    f.AddMessage = function(self, msg, r, g, b, id, hold)
        return C:Add(self, orig, msg, r, g, b, id, hold)
    end
end

for i = 1, (NUM_CHAT_WINDOWS or 7) do C:HookFrame(getglobal("ChatFrame" .. i)) end

-- -- The older options: wheel, arrows, sticky channels, long history, log-on alerts ------------

local function frames()
    local out = {}
    for i = 1, (NUM_CHAT_WINDOWS or 7) do
        local f = getglobal("ChatFrame" .. i)
        if f then table.insert(out, f) end
    end
    return out
end
C.Frames = frames

local function onWheel()
    if arg1 > 0 then
        if IsShiftKeyDown() and this.ScrollToTop then this:ScrollToTop() elseif this.ScrollUp then this:ScrollUp() end
    else
        if IsShiftKeyDown() and this.ScrollToBottom then this:ScrollToBottom() elseif this.ScrollDown then this:ScrollDown() end
    end
    C.lastActivity = now()
end
C.OnWheel = onWheel

local STICKY = { "WHISPER", "OFFICER", "RAID", "CHANNEL", "PARTY", "GUILD" }
local stickyStock = {}

function C:ApplyBehaviour()
    local on = self.active
    for _, f in ipairs(frames()) do
        if f.cpWheelOrig == nil then f.cpWheelOrig = f.GetScript and f:GetScript("OnMouseWheel") or false end
        if on and self:Get("wheel") then
            if f.EnableMouseWheel then f:EnableMouseWheel(true) end
            f:SetScript("OnMouseWheel", onWheel)
        elseif f.cpWheelOrig ~= nil then
            f:SetScript("OnMouseWheel", f.cpWheelOrig or nil)
            if not f.cpWheelOrig and f.EnableMouseWheel then f:EnableMouseWheel(false) end
        end
        local want = (on and self:Get("history")) and 1000 or nil
        if want and f.cpMaxLines ~= want and f.SetMaxLines then
            f:SetMaxLines(want)
            f.cpMaxLines = want
        elseif not want and f.cpMaxLines and f.SetMaxLines then
            f:SetMaxLines(128)
            f.cpMaxLines = nil
        end
    end
    if ChatFrameEditBox and ChatFrameEditBox.SetAltArrowKeyMode then
        ChatFrameEditBox:SetAltArrowKeyMode(not (on and self:Get("arrows")))
    end
    if ChatTypeInfo then
        for _, t in ipairs(STICKY) do
            local info = ChatTypeInfo[t]
            if info then
                if stickyStock[t] == nil then stickyStock[t] = info.sticky or 0 end
                info.sticky = (on and self:Get("sticky")) and 1 or stickyStock[t]
            end
        end
    end
    if on and SetCVar then pcall(SetCVar, "guildMemberNotify", self:Get("alerts") and "1" or "0") end
end

-- Concord's "Guild" chat tab lives in the Guilds addon's settings.
local function guildTabShown()
    return W:Setting("Guilds", "showChatTab", true) ~= false
end
function C:SetGuildTab(on)
    local s = W:Settings("Guilds")
    s.showChatTab = on and true or false
    if W.Refresh then W:Refresh("Guilds") end
end

function C:OpenSettings()
    if ClassicPlus_ToggleManager then
        if not (ClassicPlus_SettingsWindow and ClassicPlus_SettingsWindow:IsShown()) then ClassicPlus_ToggleManager() end
        if ClassicPlus_Manager and ClassicPlus_Manager.SelectAddon then ClassicPlus_Manager:SelectAddon(ID) end
    end
end

-- -- The chat tab's right-click menu ----------------------------------------------------------

local function addRows()
    if not UIDropDownMenu_AddButton or (UIDROPDOWNMENU_MENU_LEVEL and UIDROPDOWNMENU_MENU_LEVEL ~= 1) then return end
    UIDropDownMenu_AddButton({ text = "Chat", isTitle = 1, notCheckable = 1 })
    local g = {}
    g.text = "Show the Guild tab"
    g.checked = guildTabShown() and 1 or nil
    g.keepShownOnClick = 1
    g.func = function() C:SetGuildTab(not guildTabShown()) end
    UIDropDownMenu_AddButton(g)
    if W:IsActive(ID) then
        local wt = {}
        wt.text = "Show the World tab"
        wt.checked = C:Get("worldTab") and 1 or nil
        wt.keepShownOnClick = 1
        wt.func = function() C:SetOption("worldTab", not C:Get("worldTab")) end
        UIDropDownMenu_AddButton(wt)
    end
    if not W:IsActive(ID) then
        UIDropDownMenu_AddButton({ text = "Turn on the Chat addon", notCheckable = 1, func = function() W:SetAddonEnabled(ID, true) end })
        return
    end
    for _, o in ipairs(C.OPTIONS) do
        local opt = o
        local info = {}
        info.text = opt.label
        info.checked = C:On(opt.key) and 1 or nil
        info.keepShownOnClick = 1
        info.func = function() C:Set(opt.key, not C:On(opt.key)) end
        UIDropDownMenu_AddButton(info)
    end
    UIDropDownMenu_AddButton({ text = "All chat settings...", notCheckable = 1, func = function() C:OpenSettings() end })
end

local function hookMenu()
    if C.menuHooked or type(FCFOptionsDropDown_Initialize) ~= "function" then return end
    local orig = FCFOptionsDropDown_Initialize
    FCFOptionsDropDown_Initialize = function(a1, a2, a3)
        orig(a1, a2, a3)
        addRows()
    end
    C.menuHooked = true
end

-- -- /cpchat -----------------------------------------------------------------------------------

SLASH_CPCHAT1 = "/cpchat"
SLASH_CPCHAT2 = "/chatset"
SlashCmdList["CPCHAT"] = function(msg)
    msg = strlower(W.Trim(msg or ""))
    local _, _, verb, rest = strfind(msg, "^(%S+)%s*(.*)$")
    if msg == "guild" then
        C:SetGuildTab(not guildTabShown())
    elseif msg == "world" then
        C:SetOption("worldTab", not C:Get("worldTab"))
    elseif verb == "theme" then
        if C.THEMES[rest] then C:SetOption("theme", rest) end
        W.Print("Chat theme: " .. C:Theme().label .. ". Themes: slate, parchment, midnight, wildwood, glass.")
        return
    elseif msg == "expand" then
        if C.OpenExpanded then C:OpenExpanded() end
        return
    elseif msg == "copy" then
        if C.OpenCopy then C:OpenCopy() end
        return
    elseif msg == "settings" or msg == "options" then
        C:OpenSettings()
        return
    else
        for _, o in ipairs(C.OPTIONS) do
            if o.key == msg then C:Set(o.key, not C:On(o.key)) end
        end
    end
    local parts = { "guild tab " .. (guildTabShown() and "on" or "off"), "world tab " .. (C:Get("worldTab") and "on" or "off") }
    for _, o in ipairs(C.OPTIONS) do table.insert(parts, o.key .. " " .. (C:On(o.key) and "on" or "off")) end
    W.Print("Chat: " .. table.concat(parts, ", ") .. ". /cpchat <name> toggles one; /cpchat theme <name>, /cpchat copy, /cpchat expand, /cpchat settings.")
end

-- -- Registration and events -------------------------------------------------------------------

W:RegisterSchema(ID, C.SCHEMA)
W:OnConfig(function() C:Migrate() end)

function C:Refresh(active)
    local wasInked = self.inked
    self.active = active and true or false
    local theme = self:Theme()
    self.inked = self.active and theme.ink and true or false
    self:ApplyBehaviour()
    if self.ApplySkin then self:ApplySkin() end
    if self.ApplyTools then self:ApplyTools() end
    if self.ApplyWorld then self:ApplyWorld() end
    if (wasInked or false) ~= self.inked then self:RenderAll() end
end

W:RegisterAddon(ID, function(active) C:Refresh(active) end)

local ev = CreateFrame("Frame", "CPChatFrame")
ev:RegisterEvent("VARIABLES_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:RegisterEvent("RAID_ROSTER_UPDATE")
ev:RegisterEvent("GUILD_ROSTER_UPDATE")
ev:RegisterEvent("FRIENDLIST_UPDATE")
ev:RegisterEvent("WHO_LIST_UPDATE")
ev:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" or event == "PLAYER_ENTERING_WORLD" then
        store()
        hookMenu()
        for i = 1, (NUM_CHAT_WINDOWS or 7) do C:HookFrame(getglobal("ChatFrame" .. i)) end
        C:LearnUnit("player")
        if event == "PLAYER_ENTERING_WORLD" and C.OnEnterWorld then C:OnEnterWorld() end
        W:Refresh(ID)
    elseif event == "PLAYER_TARGET_CHANGED" then
        C:LearnUnit("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        C:LearnUnit("mouseover")
    elseif event == "PARTY_MEMBERS_CHANGED" then
        for i = 1, 4 do C:LearnUnit("party" .. i) end
    elseif event == "RAID_ROSTER_UPDATE" then
        for i = 1, 40 do C:LearnUnit("raid" .. i) end
    elseif event == "GUILD_ROSTER_UPDATE" then
        if GetNumGuildMembers and GetGuildRosterInfo then
            for i = 1, (GetNumGuildMembers(true) or 0) do
                local name, _, _, _, class = GetGuildRosterInfo(i)
                C:Learn(name, class)
            end
        end
    elseif event == "FRIENDLIST_UPDATE" then
        if GetNumFriends and GetFriendInfo then
            for i = 1, (GetNumFriends() or 0) do
                local name, _, class = GetFriendInfo(i)
                C:Learn(name, class)
            end
        end
    elseif event == "WHO_LIST_UPDATE" then
        if GetNumWhoResults and GetWhoInfo then
            for i = 1, (GetNumWhoResults() or 0) do
                local name, _, _, _, class = GetWhoInfo(i)
                C:Learn(name, class)
            end
        end
    end
end)
