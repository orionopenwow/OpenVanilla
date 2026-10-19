--[[
    Bindings.lua  (Essentials)
    Keybind mode (/kb, /keybind): hover an action button and press a key to bind it, with
    Shift, Ctrl and Alt as you hold them. Delete or Backspace clears the button's keys; Escape
    (or /kb again) finishes and saves. Works on the main bar, the four extra bars, the stance
    bar and the pet bar.

    Lua 5.0 rules (1.12.1 client): no '#', no '%', handlers read this/event/arg1.
]]--

local E = Essentials
local W = WenillaCore
local UI = W.UI

-- Button name -> binding command (Bindings.xml)
local COMMANDS = {
    { "^ActionButton(%d+)$", "ACTIONBUTTON", "Action Button" },
    { "^BonusActionButton(%d+)$", "ACTIONBUTTON", "Action Button" },
    { "^MultiBarBottomLeftButton(%d+)$", "MULTIACTIONBAR1BUTTON", "Bottom Left Bar" },
    { "^MultiBarBottomRightButton(%d+)$", "MULTIACTIONBAR2BUTTON", "Bottom Right Bar" },
    { "^MultiBarRightButton(%d+)$", "MULTIACTIONBAR3BUTTON", "Right Bar" },
    { "^MultiBarLeftButton(%d+)$", "MULTIACTIONBAR4BUTTON", "Right Bar 2" },
    { "^ShapeshiftButton(%d+)$", "SHAPESHIFTBUTTON", "Stance" },
    { "^PetActionButton(%d+)$", "BONUSACTIONBUTTON", "Pet Bar" },
}

-- command, label for a button (nil when it is not bindable)
function E.BindingFor(frame)
    local name = frame and frame.GetName and frame:GetName()
    if not name then return nil end
    for _, c in ipairs(COMMANDS) do
        local _, _, n = string.find(name, c[1])
        if n then return c[2] .. n, c[3] .. " " .. n end
    end
    return nil
end

local MODIFIERS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
    SHIFT = true, CTRL = true, ALT = true, UNKNOWN = true }

local function keysOf(command)
    local keys = { GetBindingKey(command) }
    return table.concat(keys, ", ")
end

-- -- The overlay ---------------------------------------------------------------------------------

local mode = CreateFrame("Frame", "EssentialsKeybindFrame", UIParent)
mode:SetAllPoints(UIParent)
mode:SetFrameStrata("DIALOG")
mode:EnableMouse(false)
mode:EnableKeyboard(true)
mode:Hide()

local banner = CreateFrame("Frame", nil, mode)
banner:SetWidth(420)
banner:SetHeight(46)
banner:SetPoint("TOP", UIParent, "TOP", 0, -90)
UI.Skin(banner, "panel")
local title = UI.Label(banner, 12, UI.ACCENT, "OUTLINE")
title:SetPoint("TOP", banner, "TOP", 0, -8)
title:SetJustifyH("CENTER")
title:SetText("Keybind mode")
local hint = UI.Label(banner, 10, UI.MUTED)
hint:SetPoint("TOP", title, "BOTTOM", 0, -4)
hint:SetJustifyH("CENTER")
hint:SetText("Hover a button and press a key. Delete clears it. Escape to finish.")
E.keybindHint = hint

-- a gold frame around the hovered button
local glow = CreateFrame("Frame", nil, mode)
glow:SetFrameStrata("TOOLTIP")
glow:SetBackdrop(UI.THIN)
glow:SetBackdropColor(1, 0.82, 0, 0.12)
glow:SetBackdropBorderColor(1, 0.82, 0, 1)
glow:Hide()

local function say(text) hint:SetText(text) end

function E.KeybindMode(on)
    if on == nil then on = not mode:IsShown() end
    if on then
        if not E.On("keybinds") then
            E.Print("Keybind mode is switched off. Turn it on in /essentials.")
            return
        end
        say("Hover a button and press a key. Delete clears it. Escape to finish.")
        mode:Show()
        E.Print("Keybind mode: hover a button and press a key. Escape to finish.")
    elseif mode:IsShown() then
        mode:Hide()
        glow:Hide()
        if SaveBindings then SaveBindings(GetCurrentBindingSet and GetCurrentBindingSet() or 1) end
        E.Print("Keybind mode off. Your key bindings are saved.")
    end
end

function E.BindKey(key)
    if not key or MODIFIERS[key] then return end
    if key == "ESCAPE" then E.KeybindMode(false) return end
    local command, label = E.BindingFor(GetMouseFocus and GetMouseFocus())
    if not command then
        say("Hover over an action button first.")
        return
    end
    if key == "DELETE" or key == "BACKSPACE" then
        local keys = { GetBindingKey(command) }
        for _, k in ipairs(keys) do SetBinding(k) end
        say(label .. ": no keys.")
        return
    end
    local full = key
    if IsShiftKeyDown() then full = "SHIFT-" .. full end
    if IsControlKeyDown() then full = "CTRL-" .. full end
    if IsAltKeyDown() then full = "ALT-" .. full end
    if SetBinding(full, command) then
        say(label .. ": " .. keysOf(command))
    end
end

mode:SetScript("OnKeyDown", function() E.BindKey(arg1) end)

local acc = 0
mode:SetScript("OnUpdate", function()
    acc = acc + arg1
    if acc < 0.05 then return end
    acc = 0
    local f = GetMouseFocus and GetMouseFocus()
    local command, label = E.BindingFor(f)
    if command then
        glow:ClearAllPoints()
        glow:SetPoint("TOPLEFT", f, "TOPLEFT", -2, 2)
        glow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2, -2)
        glow:Show()
        if f ~= mode.lastFocus then
            local keys = keysOf(command)
            say(label .. ": " .. (keys ~= "" and keys or "no keys") .. "  -  press a key")
        end
    else
        glow:Hide()
    end
    mode.lastFocus = f
end)

E.OnRefresh(function(active)
    if not (active and E.On("keybinds")) and mode:IsShown() then E.KeybindMode(false) end
end)

SLASH_ESSKB1 = "/kb"
SLASH_ESSKB2 = "/keybind"
SlashCmdList["ESSKB"] = function()
    if not W:IsActive(E.ID) then E.Print("Essentials is switched off. Turn it on in /addons.") return end
    E.KeybindMode()
end
