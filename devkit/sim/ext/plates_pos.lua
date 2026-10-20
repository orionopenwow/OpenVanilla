--[[
    ext/plates_pos.lua - nameplate screen geometry for the sim (used by tests/plates.lua).

    The sim tracks geometry rather than computing it, and api.add_nameplate leaves a plate with no
    position or size. This helper seats a plate the way the engine does (benilla-app vplates.rs):
    the plate's TOP centre on the projected head point, a 128 x 32 frame, the health bar 103 x 9
    with its BOTTOMLEFT 4,4 inside the plate's, and the name's BOTTOM on the plate's CENTER.
    Nothing else changes: plates that are never placed behave exactly as before.

        api.place_nameplate(env, plate, x, top, opts)   x, top in UI units (y up); opts.w / opts.h
                                                         override the frame size. Call again to move
                                                         the plate (only its rect changes then).
]]--
return function(api, H)
    local M, ST = H.M, api.ST
    function api.place_nameplate(env, plate, x, top, opts)
        opts = opts or {}
        local w, h = opts.w or 128, opts.h or 32
        local s = ST[plate]
        s.left, s.top, s.w, s.h = x - w / 2, top, w, h
        if not s.__seated then
            s.__seated = true
            local _, _, name = plate:GetRegions()
            local hb = plate:GetChildren()
            if hb then
                M.ClearAllPoints(hb)
                M.SetPoint(hb, "BOTTOMLEFT", plate, "BOTTOMLEFT", 4, 4)
                M.SetWidth(hb, 103)
                M.SetHeight(hb, 9)
            end
            if name then
                M.ClearAllPoints(name)
                M.SetPoint(name, "BOTTOM", plate, "CENTER", 0, 0)
            end
        end
        return plate
    end
end
