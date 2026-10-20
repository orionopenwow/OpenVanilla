--[[
    Node.lua  (Open Vanilla)
    Esc menu > "Become a Node": a window that explains what an Open Vanilla node is, what it shares and
    what it can see, how to turn one on in the launcher (HOST > Become a node) and how to turn it
    off, and the node's status as the launcher last reported it.

    The game can't run or switch the node: the launcher does. The launcher writes Status.lua
    (OpenVanillaNode_Status) whenever the node changes state; the game reads it when it starts, so the
    window says when that report was taken. /node opens the window too.
]]--

local W = WenillaCore
local N = {}
OpenVanillaNode = N

N.BUTTON_TEXT = "Become a Node"
N.WIDTH, N.HEIGHT = 460, 540

N.SECTIONS = {
    { "WHAT A NODE IS",
      "A node is a PC (or a small server) that relays other players' connections to community realms. "
      .. "Hosts don't have to open router ports and nobody's home address is shown to strangers. "
      .. "More nodes means more players can connect at once, attacks get soaked up, and the path is shorter "
      .. "for players near you. A node does not make one realm bigger: each world still runs on its host's PC." },
    { "PRIVACY AND SAFETY",
      "Your node only passes along game traffic that is encrypted end to end between the player and the "
      .. "realm's host: it can't read chat, names or sign-ins. It never shares Blizzard's game files, your "
      .. "WoW folder, your characters or anything else on your PC. Players and hosts who connect through "
      .. "you can see your IP address (as with seeding a torrent); they never see each other's. You see which "
      .. "addresses connect, which realm a connection is for, when, and how many bytes. The node keeps no logs." },
    { "HOW TO TURN IT ON",
      "1. Open the Open Vanilla launcher (it can stay open while you play).\n"
      .. "2. Go to HOST > Become a node.\n"
      .. "3. Read what is shared, set your bandwidth caps, and click Turn on. It is off until you do.\n"
      .. "4. Let the launcher ask your router to open the node port, or enter the address you forwarded.\n"
      .. "The maintainer checks new nodes for a few days before they get the NODE badge." },
    { "HOW TO TURN IT OFF",
      "In the launcher: HOST > Become a node > TURN OFF. One click; it stops at once, closes the port it "
      .. "opened and stays off. Closing the launcher also stops the node. Nothing is relayed while it is off." },
}

local STATE_TEXT = {
    pending = { "ON", "being checked by the maintainer", { 0.4, 0.85, 0.75 } },
    verified = { "ON", "verified node - thank you!", { 0.31, 0.76, 0.69 } },
    paused = { "PAUSED", "daily cap reached; resumes at midnight UTC", { 1, 0.75, 0.3 } },
    starting = { "STARTING", "the launcher was turning it on", { 1, 0.82, 0 } },
    error = { "NOT RUNNING", "the launcher couldn't start it; open HOST > Become a node", { 1, 0.4, 0.35 } },
    off = { "OFF", "nothing is relayed", { 0.7, 0.7, 0.72 } },
    consent = { "OFF", "waiting for your OK in the launcher", { 0.7, 0.7, 0.72 } },
    stopping = { "OFF", "the launcher was turning it off", { 0.7, 0.7, 0.72 } },
}

-- The status line(s) from the launcher's report: (headline, detail, color)
function N.StatusText(st)
    st = st or OpenVanillaNode_Status
    if type(st) ~= "table" or st.source ~= "launcher" then
        return "Status: unknown",
            "No report from the launcher yet. If you run a node, its status shows here the next time you start "
                .. "the game from the launcher.", { 0.7, 0.7, 0.72 }
    end
    local s = STATE_TEXT[st.state or "off"] or STATE_TEXT.off
    local head = "Your node: " .. s[1] .. " (" .. s[2] .. ")"
    local detail = "As of " .. tostring(st.updated or "?") .. "."
    if st.state == "pending" or st.state == "verified" or st.state == "paused" then
        detail = detail .. " Relayed today: " .. N.Size(st.relayed_today_mb) .. " of "
            .. tostring(st.daily_gb or "?") .. " GB, up to " .. tostring(st.kbps or "?") .. " KB/s."
        if (st.hosts or 0) > 0 then
            detail = detail .. " Carrying " .. tostring(st.hosts) .. (st.hosts == 1 and " realm." or " realms.")
        end
    end
    return head, detail .. " The game shows the launcher's last report; it can't switch the node itself.", s[3]
end

function N.Size(mb)
    mb = tonumber(mb) or 0
    if mb >= 1000 then return string.format("%.1f GB", mb / 1000) end
    return string.format("%d MB", math.floor(mb))
end

function N:Build()
    if self.frame then return self.frame end
    local UI = W.UI
    local f = UI.Window("OpenVanillaNodeFrame", { width = N.WIDTH, height = N.HEIGHT, title = N.BUTTON_TEXT,
        icon = "Interface\\Icons\\Spell_Arcane_PortalIronForge", skin = true, strata = "DIALOG" })
    if UISpecialFrames then table.insert(UISpecialFrames, "OpenVanillaNodeFrame") end

    local status = UI.Label(f, 12, UI.ACCENT, "OUTLINE")
    status:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
    status:SetWidth(N.WIDTH - 32)
    f.statusHead = status
    local sdet = UI.Label(f, 10, UI.MUTED)
    sdet:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -3)
    sdet:SetWidth(N.WIDTH - 32)
    f.statusDetail = sdet

    local anchor, gap = sdet, -12
    f.sections = {}
    for i = 1, table.getn(N.SECTIONS) do
        local sec = N.SECTIONS[i]
        local h = UI.Label(f, 11, UI.ACCENT, "OUTLINE")
        h:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, gap)
        h:SetText(sec[1])
        local body = UI.Label(f, 10, UI.WHITE)
        body:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -3)
        body:SetWidth(N.WIDTH - 32)
        body:SetText(sec[2])
        table.insert(f.sections, { head = h, body = body })
        anchor, gap = body, -10
    end

    local close = UI.Button(f, "Close", 96, 22, function() f:Hide() end)
    close:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 12)
    f.closeBtn = close
    local site = UI.Label(f, 10, UI.MUTED)
    site:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 18)
    site:SetText("Supporters and the rules: openvanilla.app/nodes")

    f:SetScript("OnShow", function() N:Refresh() end)
    f:Hide()
    self.frame = f
    return f
end

function N:Refresh()
    local f = self.frame
    if not f then return end
    local head, detail, color = N.StatusText()
    f.statusHead:SetText(head)
    f.statusHead:SetTextColor(color[1], color[2], color[3])
    f.statusDetail:SetText(detail)
end

function N:Toggle()
    local f = self:Build()
    if f:IsShown() then f:Hide() else f:Show() end
end

-- Esc menu: "Become a Node", in WenillaCore's stack of suite buttons (under AddOns, above Log Out).
function N.HookGameMenu()
    if not GameMenuFrame or N.menuButton then return end
    N.menuButton = W:GameMenuAdd("GameMenuButtonNode", N.BUTTON_TEXT, function() N:Toggle() end, 60)
end

N.HookGameMenu()

SLASH_OPENVANILLANODE1 = "/node"
SlashCmdList["OPENVANILLANODE"] = function() N:Toggle() end
