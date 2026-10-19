# Pictures of addon windows, without the game

The sim knows every frame an addon builds: its anchors, size, textures, colours, text and state.
This folder turns that into a PNG drawn the way the 1.12 client would draw it, so a window's look
can be checked (and shown) after every change, in a couple of seconds.

```
lua5.1 devkit/sim/render/shoot.lua <repo> devkit/sim/render/transmog.lua _local/shots
python3 devkit/sim/render/render.py <repo> _local/shots          # _local/shots/<shot>.png
```

| File | What it does |
|---|---|
| `shoot.lua` | runs a shots file in the sim and writes one JSON per shot |
| `dump.lua` | the JSON: every object under a window, its anchors and what it shows |
| `render.py` | lays the anchors out like the client and draws the result (needs Pillow) |
| `transmog.lua` | the Transmog window in each of its states, for a level 60 Hunter |

A shots file is a test file that returns what to draw:

```lua
local S, api = ...
S.shot("my_window", function()
    local env = S.T.addon("MyAddon", { latency = false })
    env.__slash("/myaddon")
    return env, env.MyAddonFrame
end)
```

**Drawn:** backdrops (tiled background, 8-piece edge), textures with tex coords, vertex colour,
desaturation and ADD blending, colour fills, button states (Normal, Checked, Disabled, a locked
Highlight), the stock templates the addons use (panel buttons, close button, check box), font
strings with `|c` colours, wrapping and justification. **Not drawn:** 3D models (a box with the
icons of the items it wears instead), animations, mouse-over highlights, the game world. Fonts
are DejaVu in place of the game's Friz Quadrata, so text runs a little wider or narrower.

**Textures** come from `<repo>/Data/Interface` (BLP or TGA, any case): the game's own UI files
must be extracted there, as for the sim's art checks. They are git-ignored, and pictures made
with them are for checking only, never for the website or the repo.
