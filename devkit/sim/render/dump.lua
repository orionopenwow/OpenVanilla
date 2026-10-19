--[[
    dump.lua - writes a window (a frame and everything under it) as JSON for render.py to draw.

        local dump = dofile("devkit/sim/render/dump.lua")(api)
        dump(env, env.TransmogFrame, "out/transmog.json", { env.GameTooltip })

    Each object: id, kind (frame type or Texture/FontString), parent, anchors, size, layer, strata,
    level, shown, texture/color/texcoord/vertex, text/font/colour/justify, backdrop, template,
    button state (checked, enabled, which textures are its Normal/Pushed/... ones), model items.
    Nothing is laid out here: anchors stay as the addon set them, render.py resolves them.
]]--
return function(api)
    local FONTS = { "GameFontNormal", "GameFontNormalSmall", "GameFontNormalLarge", "GameFontHighlight",
        "GameFontHighlightSmall", "GameFontHighlightLarge", "GameFontDisable", "GameFontDisableSmall",
        "GameFontGreen", "GameFontRed", "GameFontWhite", "NumberFontNormal", "NumberFontNormalSmall",
        "ChatFontNormal", "SystemFont", "GameFontBlack" }

    local function json(v, out)
        local t = type(v)
        if t == "nil" then table.insert(out, "null")
        elseif t == "boolean" then table.insert(out, v and "true" or "false")
        elseif t == "number" then
            if v ~= v or v == math.huge or v == -math.huge then table.insert(out, "0")
            else table.insert(out, string.format("%.6g", v)) end
        elseif t == "string" then
            local s = string.gsub(v, '[%c"\\]', function(c)
                if c == '"' then return '\\"' elseif c == "\\" then return "\\\\"
                elseif c == "\n" then return "\\n" else return string.format("\\u%04x", string.byte(c)) end
            end)
            table.insert(out, '"' .. s .. '"')
        elseif t == "table" then
            local n = table.getn(v)
            local isArr = n > 0 or next(v) == nil
            if isArr then
                table.insert(out, "[")
                for i = 1, n do if i > 1 then table.insert(out, ",") end json(v[i], out) end
                table.insert(out, "]")
            else
                table.insert(out, "{")
                local first = true
                for k, x in pairs(v) do
                    if type(k) == "string" or type(k) == "number" then
                        if not first then table.insert(out, ",") end
                        first = false
                        json(tostring(k), out); table.insert(out, ":"); json(x, out)
                    end
                end
                table.insert(out, "}")
            end
        else table.insert(out, "null") end
    end

    return function(env, root, path, extra)
        local fontName = {}
        for _, n in ipairs(FONTS) do if env[n] then fontName[env[n]] = n end end
        local ids, list = {}, {}
        local function add(o)
            if ids[o] then return end
            local s = api.state(o)
            if not s then return end
            table.insert(list, o)
            ids[o] = table.getn(list)
            for _, r in ipairs(s.regions) do add(r) end
            for _, c in ipairs(s.children) do add(c) end
        end
        add(root)
        for _, o in ipairs(extra or {}) do add(o) end
        local uip = env.UIParent
        local out = {}
        for i, o in ipairs(list) do
            local s = api.state(o)
            local points = {}
            for _, p in ipairs(s.points) do
                local rel = p[2]
                local relId
                if rel == nil then relId = "parent"
                elseif rel == uip then relId = "UIParent"
                elseif ids[rel] then relId = ids[rel]
                else relId = "parent" end
                table.insert(points, { p[1], relId, p[3] or p[1], p[4] or 0, p[5] or 0 })
            end
            local font = s.font
            if type(font) == "table" then font = fontName[font] or "GameFontNormal" end
            local states = {}
            for _, k in ipairs({ "Normal", "Pushed", "Highlight", "Disabled", "Checked" }) do
                if s[k] and ids[s[k]] then states[k] = ids[s[k]] end
            end
            local rec = {
                id = i, kind = s.otype, name = s.name, parent = s.parent and ids[s.parent] or nil,
                region = s.isRegion and true or false, shown = s.shown and true or false,
                points = points, w = s.w or 0, h = s.h or 0, layer = s.layer, strata = s.strata,
                level = s.level or 1, alpha = s.alpha or 1, scale = s.scale or 1,
                texture = s.texture, color = s.color, texcoord = s.texcoord, vertex = s.vertex,
                desat = s.desat and true or nil, blend = s.blend, circular = s.circular,
                text = s.text, font = font, fontPath = s.fontPath, textColor = s.textColor,
                justifyH = s.justifyH, justifyV = s.justifyV,
                template = s.template, backdrop = s.backdrop, backdropColor = s.backdropColor,
                backdropBorder = s.backdropBorder, checked = s.checked and true or nil,
                enabled = s.enabled and true or false, lockedHighlight = s.lockedHighlight and true or nil,
                states = states, fontString = s.fontString and ids[s.fontString] or nil,
                barTexture = s.barTexture and ids[s.barTexture] or nil, value = s.value,
                min = s.min, max = s.max, barColor = s.barColor,
                model = s.tried, dressed = s.dressed, rotation = s.rotation,
            }
            table.insert(out, rec)
        end
        local items = {}
        for id, it in pairs(env.__items or {}) do
            items[tostring(id)] = { name = it.name, icon = it.icon, quality = it.quality, equip = it.equip }
        end
        local buf = {}
        json({ screen = { 1024, 768 }, root = 1, objects = out, items = items }, buf)
        local f = assert(io.open(path, "w"))
        f:write(table.concat(buf))
        f:close()
        return table.getn(out)
    end
end
