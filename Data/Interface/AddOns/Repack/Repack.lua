--[[
    Repack.lua  (Classic+ UI Repack)
    A Workshop item: the whole-interface makeover (Elv.lua), off until a player adds it.
    Add:    Classic+ menu > Workshop > UI Repack > Add   (or /workshop add repack)
    Remove: the same button, now "Remove"                 (or /workshop remove repack)
]]--

local T = ClassicPlusUI

T:RegisterWorkshop({
    key = "repack",
    title = "UI Repack",
    tagline = "ElvUI-style",
    desc = "A complete interface makeover: flat dark panels, centre unit frames, one action-bar block, a square minimap and docked chat and Meters.",
    apply = function() if T.Elv then T.Elv:Apply() end end,
})
