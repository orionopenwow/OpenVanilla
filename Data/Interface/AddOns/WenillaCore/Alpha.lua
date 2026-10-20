--[[
    Alpha.lua  (WenillaCore)
    A faint "Alpha test v0.1.x" in the bottom-right corner while playing: small, grey, mostly
    see-through, and it never takes the mouse. The number is the site's ("Alpha v0.1.8" on
    openvanilla.app); tests/test_alpha_tag.py fails if the two differ, so bump them together.
]]--

local W = WenillaCore
W.ALPHA = "0.1.8"

local tag = CreateFrame("Frame", "WenillaCore_AlphaTag", UIParent)
tag:SetFrameStrata("BACKGROUND")
tag:SetWidth(140); tag:SetHeight(12)
tag:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -6, 3)
if tag.EnableMouse then tag:EnableMouse(false) end
local text = tag:CreateFontString("WenillaCore_AlphaTagText", "OVERLAY", "GameFontNormalSmall")
text:SetPoint("BOTTOMRIGHT", tag, "BOTTOMRIGHT", 0, 0)
if text.SetFont then text:SetFont("Fonts\\FRIZQT__.TTF", 9) end
text:SetTextColor(0.85, 0.85, 0.85)
text:SetAlpha(0.35)
text:SetText("Alpha test v" .. W.ALPHA)
tag.text = text
tag:Show()
