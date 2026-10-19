--[[
    Armory.lua  -  who can see this character on the website's armory (docs/ARMORY.md).

    Social's settings sheet gets "Armory: Public / Friends only / Hidden" (public by default; the
    realm keeps the setting, not this client). /armory prints the setting and the link.

        Public        everyone: search, rankings, guild pages
        Friends only  only people you give the link to (it carries a secret key); a new key retires
                      the old link
        Hidden        nothing (guild pages only count you)

    Client -> server:  .wnl armory                  ask for the current setting (once per connection)
                       .wnl armory <public|friends|hidden>
                       .wnl armory newlink          a new secret (friends-only links)
    Server -> client:  AR <mode>,<secret>           (secret empty until friends-only was picked once)
                       AR err,<reason>              off | rate | bad
    The website updates within ten minutes of the next logout.

    Lua 5.0 rules (1.12.1 client): no '#', no '%' operator, handlers read this/event/arg1.
]]--

local W = WenillaCore
local S = Social
local ID = "Social"
local strfind, strsub, strlower, strbyte, gsub = string.find, string.sub, string.lower, string.byte, string.gsub

S.ARMORY_SITE = "https://openvanilla.app/armory/character.html"
S.ARMORY_MODES = {
    { value = "public", label = "Public" },
    { value = "friends", label = "Friends only" },
    { value = "hidden", label = "Hidden" },
}
local LABEL = { public = "Public", friends = "Friends only", hidden = "Hidden" }

S.armory = { mode = nil, key = "", asked = false, pendingLink = false, err = nil }

-- the realm's folder name on the site: docs/ARMORY_GUILDS.md's slug rule
function S.ArmorySlug(s)
    s = gsub(strlower(s or ""), "[^a-z0-9]+", "-")
    s = gsub(s, "^%-+", "")
    s = gsub(s, "%-+$", "")
    return s
end

local function urlencode(s)
    return (gsub(s or "", "([^%w%-_%.~])", function(c) return string.format("%%%02X", strbyte(c)) end))
end

-- The link to this character's page (friends only: with the key); nil while hidden or unknown.
function S:ArmoryLink()
    local a = self.armory
    if a.mode == "hidden" or not a.mode then return nil end
    if a.mode == "friends" and (not a.key or a.key == "") then return nil end
    local url = S.ARMORY_SITE .. "?r=" .. urlencode(S.ArmorySlug(GetRealmName and GetRealmName() or ""))
        .. "&n=" .. urlencode(UnitName("player") or "")
    if a.mode == "friends" then url = url .. "&k=" .. a.key end
    return url
end

-- A dialog with the link selected, ready for Ctrl+C.
function S:ShowArmoryLink()
    local url = self:ArmoryLink()
    if not url then
        if self.armory.mode == "hidden" then
            W.Print("Your armory page is hidden. Pick Public or Friends only in Social's settings (or /armory public).")
        else
            W.Print("Asking the realm for your armory setting...")
            self.armory.pendingLink = true
            self:AskArmory(true)
        end
        return
    end
    local p = W.UI.Prompt({ title = "Your armory link", maxLetters = 255, accept = "Done", default = url,
        text = (self.armory.mode == "friends" and "Friends only: anyone with this link can see the page. Ctrl+C to copy."
            or "Public: anyone can find this page. Ctrl+C to copy."), onAccept = function() end })
    return p
end

function S:SetArmory(mode)
    if mode ~= "public" and mode ~= "friends" and mode ~= "hidden" and mode ~= "newlink" then return false end
    if not W.connected then
        W.Print("The armory setting lives on the realm, and the Classic+ server channel isn't connected (/wnl status).")
        return false
    end
    if not W:SendCommand("armory", mode) then return false end
    if mode ~= "newlink" then self.armory.mode = mode end
    self.armory.pendingLink = (mode == "friends" or mode == "newlink")
    return true
end

function S:AskArmory(force)
    if not W.connected then return end
    if self.armory.asked and not force then return end
    if W:SendCommand("armory") then self.armory.asked = true end
end

function S:OnArmory(body)
    local _, _, a, b = strfind(body or "", "^(%a+),([%w]*)$")
    if not a then return end
    a = strlower(a)
    local a2 = self.armory
    if a == "err" then
        a2.err = b
        a2.pendingLink = false
        if b == "off" then
            W.Print("This realm doesn't offer the armory setting yet.")
        elseif b == "rate" then
            W.Print("Armory: one change every few seconds, please.")
        end
    elseif LABEL[a] then
        a2.mode, a2.key, a2.err = a, strlower(b or ""), nil
        if a2.pendingLink then
            a2.pendingLink = false
            if a == "friends" or a == "public" then self:ShowArmoryLink() end
        end
    end
    if self.sheet and self.sheet:IsShown() then self.sheet:Refresh() end
end

W:RegisterModule("AR", function(body) S:OnArmory(body) end)

-- The settings sheet rows (Social.lua calls this when it builds its sheet).
function S.AddArmorySheet(sheet)
    if sheet.AddHeader then sheet:AddHeader("Armory") end
    sheet:AddChoice("Armory", S.ARMORY_MODES,
        function() return S.armory.mode or "public" end,
        function(v) S:SetArmory(v) end)
    sheet:AddButton("Copy my armory link", function() S:ShowArmoryLink() end)
end

-- /armory [public|friends|hidden|newlink|link]
SLASH_OWARMORY1 = "/armory"
SlashCmdList["OWARMORY"] = function(msg)
    if not W:IsActive(ID) then W.Print("Social is switched off. Turn it on in /addons.") return end
    msg = strlower(W.Trim(msg or ""))
    if msg == "friends only" then msg = "friends" end
    if msg == "public" or msg == "friends" or msg == "hidden" or msg == "newlink" then
        if S:SetArmory(msg) and msg ~= "newlink" then
            W.Print("Armory: " .. LABEL[msg] .. ". The website updates within ten minutes of your next logout.")
        end
        return
    end
    if msg == "link" then S:ShowArmoryLink() return end
    local m = S.armory.mode
    W.Print("Armory: " .. (m and LABEL[m] or "unknown (not connected)") .. "   |cff888888/armory public | friends | hidden | newlink | link|r")
    if m and m ~= "hidden" then W.Print("Your page: |cffffd100" .. (S:ArmoryLink() or "(ask again in a moment)") .. "|r") end
end

-- Ask once per connection, a moment after the suite connects.
local acc = 0
local ev = CreateFrame("Frame", "Social_ArmoryEvents")
ev:SetScript("OnUpdate", function()
    acc = acc + (arg1 or 0)
    if acc < 1 then return end
    acc = 0
    if not W.connected then S.armory.asked = false return end
    if W:IsActive(ID) then S:AskArmory(false) end
end)

-- for tests
function S.ResetArmory() S.armory = { mode = nil, key = "", asked = false, pendingLink = false } acc = 0 end
