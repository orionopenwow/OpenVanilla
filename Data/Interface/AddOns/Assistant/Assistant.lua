--[[
    Assistant.lua
    "Activate your AI": a window of ready-made prompts for the AI coding agent the player runs
    OUTSIDE the game (Claude Code, or any agent that reads AGENTS.md), and short how-tos.

    Nothing here talks to an AI or to the network. The game has no clipboard API, so the chosen
    prompt sits in a read-only edit box with its text selected: Ctrl+C copies it. The launcher
    (Settings > AI) has a Copy button for the same prompts, and they are files in Agent\prompts\.

    Opens with /assistant (/ai), from the Esc menu (Assistant, under AddOns) and from the Classic+
    micro menu. Prompts.lua holds the library (generated from agent/prompts/*.md).

    Lua 5.0 rules (1.12.1 client): no '#', no '%', handlers read this/event/arg1.
]]--

Assistant = Assistant or {}
local A = Assistant
local W = WenillaCore
local UI = W.UI
local ID = "Assistant"
A.ID = ID
A.PROMPTS = A.PROMPTS or {}

A.DEFAULTS = { escButton = false }   -- off: the Esc menu stays short (/assistant opens it)

local WIDTH, HEIGHT = 560, 430
local LIST_W = 180
local ICON = "Interface\\Icons\\INV_Misc_Note_02"

A.HOWTO = {
    { "1. Get an AI coding agent",
      "Claude Code works best (it reads CLAUDE.md by itself); other agents that edit files work too. "
      .. "You use your own account with its maker: Open Vanilla stores no AI keys or logins." },
    { "2. Set up the workspace",
      "In the launcher: Settings > AI > Set up AI workspace. It copies a short guide (CLAUDE.md, AGENTS.md) "
      .. "and these prompts into your Open Vanilla data folder." },
    { "3. Open it",
      "Press Open in Claude Code: a terminal opens in that folder. Other tools: open the folder in them." },
    { "4. Paste a prompt",
      "Pick one on the Prompts tab, press Ctrl+C, paste it into the agent and fill in the <...> parts. "
      .. "Back in game, /reload loads changed addons; restart your realm from the launcher for server changes." },
    { "Stay safe",
      "It changes your own copy and your own servers only: the official realm can't be touched from here. "
      .. "Never paste passwords or tokens into an AI. The agent backs files up to Backups\\ first; read what "
      .. "it proposes before you say yes." },
}

local function setting(key)
    local v = W:Setting(ID, key, A.DEFAULTS[key])
    return v and true or false
end

-- -- Settings ------------------------------------------------------------------------------

W:RegisterSchema(ID, {
    icon = ICON,
    title = "Assistant",
    desc = "Ready-made prompts for the AI coding agent you run outside the game: make addons, change your own realm, host for friends. /assistant",
    defaults = A.DEFAULTS,
    options = {
        { key = "escButton", label = "Button in the Esc menu", sub = "An Assistant button under AddOns in the game menu." },
    },
})

-- -- The prompt list -----------------------------------------------------------------------

function A.Find(id)
    for i, p in ipairs(A.PROMPTS) do
        if p.id == id then return p, i end
    end
    return nil
end

-- The chosen prompt, selected in the copy box so Ctrl+C takes it.
function A.SelectAll()
    local box = A.box
    if not box then return end
    box:SetFocus()
    box:HighlightText()
    A.highlighted = true
end

function A.Select(i)
    local p = A.PROMPTS[i]
    local win = A.window
    if not p or not win then return end
    A.current = i
    for j, b in ipairs(win.rows) do
        if j == i then b:LockHighlight() else b:UnlockHighlight() end
    end
    win.ptitle:SetText(p.title)
    win.psummary:SetText(p.summary or "")
    win.pworks:SetText((p.works and p.works ~= "") and ("Works on: " .. p.works) or "")
    A.copyText = p.text
    A.box:SetText(p.text)
    if A.scroll and A.scroll.SetVerticalScroll then A.scroll:SetVerticalScroll(0) end
    local s = W:Settings(ID)
    s.last = p.id
    A.SelectAll()
end

local function page(win, key)
    local p = CreateFrame("Frame", nil, win)
    p:SetPoint("TOPLEFT", win, "TOPLEFT", 8, -52)
    p:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -8, 30)
    UI.Skin(p, "inset")
    win.pages[key] = p
    return p
end

local function build()
    if A.window then return A.window end
    local win = UI.Window("AssistantFrame", { width = WIDTH, height = HEIGHT, title = "Assistant",
        icon = ICON, titleAlign = "LEFT", skin = true })
    win:Hide()
    table.insert(UISpecialFrames, "AssistantFrame")
    A.window = win
    win.pages = {}
    win.rows = {}

    local tabs = UI.Tabs(win, {
        tabs = { { key = "prompts", label = "Prompts" }, { key = "howto", label = "How it works" } },
        onSelect = function(key)
            for k, p in pairs(win.pages) do if k == key then p:Show() else p:Hide() end end
        end,
        skin = true,
    })
    tabs:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -30)
    win.tabs = tabs

    -- Prompts: the list on the left, the chosen one on the right
    local pp = page(win, "prompts")
    for i, p in ipairs(A.PROMPTS) do
        local idx = i
        local b = CreateFrame("Button", "AssistantPromptButton" .. i, pp)
        b:SetWidth(LIST_W)
        b:SetHeight(24)
        b:SetPoint("TOPLEFT", pp, "TOPLEFT", 8, -8 - (i - 1) * 26)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        UI.Font(fs, 11)
        fs:SetPoint("LEFT", b, "LEFT", 6, 0)
        fs:SetWidth(LIST_W - 10)
        fs:SetJustifyH("LEFT")
        fs:SetText(p.title)
        b.label = fs
        b:SetScript("OnClick", function() A.Select(idx) end)
        win.rows[i] = b
    end

    local rx = LIST_W + 22
    local rw = WIDTH - 16 - rx - 12
    win.ptitle = UI.Label(pp, 13, UI.ACCENT, "OUTLINE")
    win.ptitle:SetPoint("TOPLEFT", pp, "TOPLEFT", rx, -10)
    win.ptitle:SetWidth(rw)
    win.psummary = UI.Label(pp, 10, { 0.92, 0.92, 0.92 })
    win.psummary:SetPoint("TOPLEFT", win.ptitle, "BOTTOMLEFT", 0, -6)
    win.psummary:SetWidth(rw)
    win.pworks = UI.Label(pp, 10, UI.MUTED)
    win.pworks:SetPoint("TOPLEFT", win.psummary, "BOTTOMLEFT", 0, -4)
    win.pworks:SetWidth(rw)

    -- the copy box: read-only, its text selected so Ctrl+C copies it
    local holder = CreateFrame("Frame", nil, pp)
    UI.Skin(holder, "inset")
    holder:SetWidth(rw)
    holder:SetHeight(170)
    holder:SetPoint("TOPLEFT", pp, "TOPLEFT", rx, -78)
    local sf = CreateFrame("ScrollFrame", "AssistantCopyScroll", holder, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", holder, "TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -26, 6)
    local box = CreateFrame("EditBox", "AssistantCopyBox", sf)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetMaxLetters(2000)
    box:SetWidth(rw - 34)
    box:SetHeight(400)
    box:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    box:SetScript("OnTextChanged", function()
        -- read-only: typing puts the prompt back (and selects it again)
        if A.copyText and this:GetText() ~= A.copyText then
            this:SetText(A.copyText)
            this:HighlightText()
        end
    end)
    box:SetScript("OnEditFocusGained", function() this:HighlightText() end)
    box:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    sf:SetScrollChild(box)
    A.box, A.scroll = box, sf
    win.copyHolder = holder

    local sel = UI.Button(pp, "Select all", 100, 22, function() A.SelectAll() end)
    sel:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", 0, -8)
    local hint = UI.Label(pp, 10, UI.MUTED)
    hint:SetPoint("LEFT", sel, "RIGHT", 10, 0)
    hint:SetWidth(rw - 112)
    hint:SetText("Ctrl+C copies it. Paste it into your AI tool and fill in the <...> parts.")
    win.hint = hint

    -- How it works
    local hp = page(win, "howto")
    local y = -10
    for _, h in ipairs(A.HOWTO) do
        local t = UI.Label(hp, 11, UI.ACCENT, "OUTLINE")
        t:SetPoint("TOPLEFT", hp, "TOPLEFT", 14, y)
        t:SetText(h[1])
        local b = UI.Label(hp, 10, { 0.92, 0.92, 0.92 })
        b:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -3)
        b:SetWidth(WIDTH - 60)
        b:SetText(h[2])
        y = y - 62
    end

    -- the footer, on every tab: where the AI actually runs
    local foot = UI.Label(win, 10, UI.MUTED)
    foot:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 12, 10)
    foot:SetWidth(WIDTH - 24)
    foot:SetText("The AI runs outside the game, in its own window, on your PC. Nothing here sends anything anywhere.")
    win.footer = foot

    tabs:Select("prompts")
    return win
end

function A.Show(tab)
    if not W:IsActive(ID) then
        W.Print("Assistant is switched off: /addons to turn it on.")
        return
    end
    local win = build()
    win:Show()
    win.tabs:Select(tab or "prompts")
    if (tab or "prompts") == "prompts" then
        local _, i = A.Find(W:Setting(ID, "last", nil))
        A.Select(A.current or i or 1)
    end
end

function A.Toggle(tab)
    if A.window and A.window:IsShown() and not tab then
        A.window:Hide()
        return
    end
    A.Show(tab)
end

-- -- Esc menu: an Assistant button under AddOns ---------------------------------------------

local function setEscButton(show)
    if not GameMenuFrame then return end
    if not GameMenuButtonAssistant then
        if not show then return end
        W:GameMenuAdd("GameMenuButtonAssistant", "Assistant", function() A.Show() end, 50)
    end
    W:GameMenuShow("GameMenuButtonAssistant", show)
end
A.SetEscButton = setEscButton

W:RegisterAddon(ID, function(active)
    setEscButton(active and setting("escButton"))
    if not active and A.window then A.window:Hide() end
end)

SLASH_ASSISTANT1 = "/assistant"
SLASH_ASSISTANT2 = "/ai"
SlashCmdList["ASSISTANT"] = function(msg)
    msg = string.lower(W.Trim(msg or ""))
    if msg == "how" or msg == "help" then A.Toggle("howto") return end
    A.Toggle()
end
