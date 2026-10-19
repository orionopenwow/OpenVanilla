--[[
    Themes.lua  (Classic+ Interface)
    The Workshop: optional interface packs a player adds to their game. Nothing in it is on until
    the player adds it; the default is the stock 1.12 UI with the Classic+ addons.

        /workshop               open the Workshop window (also Classic+ menu > Workshop)
        /workshop add repack    add an item (reloads the interface)
        /workshop remove repack take it out again

    An item registers itself (Repack/Repack.lua does) with:
        ClassicPlusUI:RegisterWorkshop({ key, title, tagline, desc, apply = function() ... end })
    Added items are remembered account-wide in ClassicPlus_UI.workshop and applied at load.
    Move Anything (Move.lua) is not a Workshop item: everyone has it (/move).
]]--

local T = ClassicPlusUI
local W = WenillaCore

T.WORKSHOP = {}

function T:RegisterWorkshop(item)
    table.insert(self.WORKSHOP, item)
    if self.window and self.window:IsShown() then self:RenderWorkshop() end
end

local function added()
    local d = T.db()
    if type(d.workshop) ~= "table" then d.workshop = {} end
    return d.workshop
end

function T:IsAdded(key) return added()[key] == true end

local function find(key)
    for _, it in ipairs(T.WORKSHOP) do if it.key == key then return it end end
end

function T:SetAdded(key, on)
    local it = find(key)
    if not it then W.Print("No Workshop item called '" .. tostring(key) .. "'.") return end
    if (self:IsAdded(key)) == (on and true or false) then return end
    added()[key] = on and true or nil
    W.Print(it.title .. (on and " added" or " removed") .. ". Reloading the interface...")
    if ReloadUI then ReloadUI() end
end

-- -- The Workshop window --------------------------------------------------------------------------

local ROW_H = 92

function T:BuildWorkshop()
    if self.window then return self.window end
    local UI = W.UI
    local f
    if UI and UI.Window then
        f = UI.Window("ClassicPlusWorkshop", { width = 420, height = 150, title = "Workshop", icon = "Interface\\Icons\\INV_Misc_Note_01", skin = true })
    else
        f = CreateFrame("Frame", "ClassicPlusWorkshop", UIParent)
        f:SetWidth(420)
        f:SetHeight(150)
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        f:SetBackdropColor(0.06, 0.06, 0.07, 0.95)
        f:SetBackdropBorderColor(0, 0, 0, 1)
        f:EnableMouse(true)
    end
    f:SetFrameStrata("DIALOG")
    if UISpecialFrames then table.insert(UISpecialFrames, "ClassicPlusWorkshop") end
    local intro = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    intro:SetWidth(392)
    intro:SetJustifyH("LEFT")
    intro:SetText("Optional packs for your interface. Nothing here is on until you add it, and you can take it out again any time.")
    f.rows = {}
    f:Hide()
    self.window = f
    return f
end

function T:RenderWorkshop()
    local f = self:BuildWorkshop()
    local UI = W.UI
    for i, it in ipairs(self.WORKSHOP) do
        local row = f.rows[i]
        if not row then
            row = CreateFrame("Frame", nil, f)
            row:SetHeight(ROW_H - 6)
            row:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -62 - (i - 1) * ROW_H)
            row:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -62 - (i - 1) * ROW_H)
            row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
            row:SetBackdropColor(1, 1, 1, 0.03)
            row:SetBackdropBorderColor(0.25, 0.27, 0.32, 1)
            row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -8)
            row.tag = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.tag:SetPoint("LEFT", row.title, "RIGHT", 8, 0)
            row.desc = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.desc:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -28)
            row.desc:SetWidth(270)
            row.desc:SetJustifyH("LEFT")
            local b = (UI and UI.Button) and UI.Button(row, "Add", 92, 24) or CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            if not (UI and UI.Button) then b:SetWidth(92); b:SetHeight(24) end
            b:SetPoint("RIGHT", row, "RIGHT", -10, 0)
            row.button = b
            f.rows[i] = row
        end
        local item = it
        row.title:SetText(item.title)
        row.tag:SetText(self:IsAdded(item.key) and "|cff40ff40Added|r" or ("|cff9aa0aa" .. (item.tagline or "") .. "|r"))
        row.desc:SetText(item.desc or "")
        row.button:SetText(self:IsAdded(item.key) and "Remove" or "Add")
        row.button:SetScript("OnClick", function() T:SetAdded(item.key, not T:IsAdded(item.key)) end)
        row:Show()
    end
    f:SetHeight(70 + table.getn(self.WORKSHOP) * ROW_H)
end

function T:ToggleWorkshop()
    local f = self:BuildWorkshop()
    if f:IsShown() then f:Hide() return end
    self:RenderWorkshop()
    f:Show()
end

SLASH_CPWORKSHOP1 = "/workshop"
SlashCmdList["CPWORKSHOP"] = function(msg)
    msg = string.lower(msg or "")
    local _, _, verb, key = string.find(msg, "^(%a+)%s+(%S+)")
    if verb == "add" then return T:SetAdded(key, true) end
    if verb == "remove" then return T:SetAdded(key, false) end
    T:ToggleWorkshop()
end

-- Older name for the same switch, kept so "/theme elv" from earlier notes still works.
SLASH_CPTHEME1 = "/theme"
SlashCmdList["CPTHEME"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "elv" or msg == "repack" then return T:SetAdded("repack", true) end
    if msg == "default" then return T:SetAdded("repack", false) end
    T:ToggleWorkshop()
end

-- -- Apply what the player has added --------------------------------------------------------------

local ev = CreateFrame("Frame", "ClassicPlusThemeEvents")
ev:RegisterEvent("VARIABLES_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function()
    for _, it in ipairs(T.WORKSHOP) do
        if T:IsAdded(it.key) and it.apply and not it.applied then
            it.applied = true
            local ok, err = pcall(it.apply)
            if not ok then W.Print(it.title .. " failed to load: " .. tostring(err)) end
        end
    end
end)

-- -- Window skin ------------------------------------------------------------------------------------
-- The look of the Classic+ windows that follow it (Loot, Bags, Talents and the Workshop): Classic
-- (the stock 1.12 textures, the default), Brass (the Classic+ gold-and-stone art) or Slick (flat
-- dark panels). Saved in WenillaCore_Config.settings.Themes.skin; /skin also sets it.

if W.UI and W.UI.SKINS then
    local UI = W.UI
    local choices = {}
    for _, k in ipairs(UI.SKIN_ORDER) do table.insert(choices, { value = k, label = UI.SKINS[k].label }) end
    W:RegisterSchema("Themes", {
        title = "Themes - Look & Layout",
        icon = "Interface\\Icons\\INV_Misc_Note_01",
        desc = "How the Classic+ windows look, Move Anything (/move) and the Workshop (/workshop).",
        defaults = { skin = "classic" },
        options = {
            { key = "skin", type = "choice", label = "Window skin", choices = choices,
              sub = "Classic: the game's own 1.12 frames. Brass: the Classic+ gold-and-stone art. Slick: flat dark panels." },
        },
    })
    -- the Addons window changed the setting: re-skin when it differs from what is shown
    W:RegisterAddon("Themes", function()
        if UI.appliedSkin ~= UI.SkinKey() then UI.ApplySkin() end
    end)
end
