# UI Studio

`UI_Studio.bat` (repo root) opens a page in your browser that draws the real Open Vanilla windows, the way the Lua sim builds them from the addon code, and lets you tune them by hand. Every change is written straight to `Data/Interface/AddOns/WenillaCore/Layout.lua`, which the addons read when they load. Undo walks back; the Changes tab lists everything.

```
UI_Studio.bat
UI_Studio.bat --game "C:\Games\World of Warcraft"    your 1.12 folder, for in-game positions
python devkit/uistudio/server.py --port 18095 --no-browser
```

| Tab | What it does |
|---|---|
| Windows | Every shot: `devkit/uistudio/shots/*.lua` plus the render shots in `devkit/sim/render/`. |
| Theme | The W.UI tokens every Classic+ window reads: window face and edge, title strip, text colour and size, accent, `FONT_SCALE`, `FONT`. |
| Tunables | Every `W:Tune("Addon.key", default)` in the addons (the loot recap's offset from your character is one). Picked up at /reload. |
| Inspect | The selected piece: anchor point, x/y, width/height, scale, alpha, text colour, size and font, texture tint, fill and art, backdrop face, edge and 9-slice art, hide, sticky. Plus the piece tree. |
| Art | Drop a PNG: it becomes `Media/<name>.tga` (desktop) and `ClassicPlus/<name>.blp` (browser), either a texture (power of two, stretched or padded) or a 9-slice window backdrop (`<name>_Edge` + `<name>_Bg`). Swap it in for any `W:Art` name, or click it onto the selected texture. |
| Game | Reads the positions you set in game (`/move`, and Classic+ windows you dragged) from `WTF\Account\*\SavedVariables` and imports the ones you tick as Layout.lua defaults. Copies Layout.lua and its art into the game's WenillaCore folder. |

On the picture: click selects the smallest piece under the pointer, drag moves it, the green corner resizes it, double-click selects its parent (grab a window by its title), Alt-click picks through, arrow keys nudge (Shift = 10), Delete resets it, Esc deselects.

## How the addons read it

`Layout.lua` holds `WenillaCore_Layout = { theme, frames, tune, art }`. `UI.lua` applies the theme at load; `UI.Window` places a window from its entry before the player's saved position goes on (theirs wins); `LayoutKit.lua` applies the rest of every entry as soon as its object exists (twice a second, only the listed paths). A path is a global name plus fields (`Loot_Recap.rows.2.text`); `.@text` is a button's label. `sticky = true` re-applies whenever the addon changes it back. `W:Art(tex, name)` checks `art[name]` first; `W:Tune(key, default)` returns `tune[key]` when it has the default's type.

The browser client gets the BLP copies after patch-Z is rebuilt (`tools/sync_patchz.py`).

## Adding a window

Copy a shot from `shots/suite.lua`: a shot loads an addon in the sim, opens the window, and returns `env, frame`. Any window the sim can build can be tuned.

Files: `server.py` (HTTP on 127.0.0.1, rendering, image pipeline, import), `index.html` (the page), `runner.lua` + `shoot_one.lua` (Lua side, through lupa or a lua5.1), `shots/`. Tests: `tests/test_uistudio.py`, `devkit/sim/tests/layout.lua`.
