# Lua sim: run the Classic+ addons outside the game

The sim loads every addon in `Data/Interface/AddOns` into a fake 1.12.1 client (no game data, no
network), feeds it server packets, chat, clicks and time, and checks what the windows show. The
whole suite runs in about two seconds.

## Run it

```
lua5.1 devkit/sim/run_tests.lua                 # repo = two folders above this one
lua5.1 devkit/sim/run_tests.lua /path/to/repo   # any repo checkout
lua5.1 devkit/sim/run_tests.lua persona         # only tests whose name or file contains "persona"
SIM_VERBOSE=1 lua5.1 devkit/sim/run_tests.lua   # also: why each known bug fails, unmodelled API use
```

Each test prints one line:

* `PASS`: fine.
* `FAIL`: broken. The exit code is 1.
* `XFAIL`: a known addon bug that is still there. It does not fail the run.

A test fails on its own assertions. It also fails if any client it made hit a Lua error, or if an
addon's own `pcall` quietly swallowed an error.

## Files

| File | What it is |
|---|---|
| `wow_api.lua` | The fake client. `api.new_client{...}` returns a sandbox you can pass to `setfenv` |
| `lua50_guard.lua` | Scans each addon file for Lua 5.1-only syntax before it runs |
| `testkit.lua` | The `T` helpers (assertions, `T.addon`, `T.suite`, `T.known_bug`) |
| `run_tests.lua` | The runner |
| `tests/*.lua` | One file per addon, plus `smoke.lua` (the whole suite) and `harness.lua` (tests of the fake itself) |
| `data/` | 1.12 global, widget-method and event names, taken from the wenilla reference tables |

## Writing a test (for example, after fixing a bug)

Add it to the addon's file in `tests/`:

```lua
local T, api = ...

T.test("Threat: VG with a lone tank hides the second bar", function()
    local env = T.addon("Threat")                 -- client + Threat + its deps, logged in
    api.server_packet(env, "VG", "Hogger;Herald,100,1;S,1,100,110")
    T.hidden(env.Vanguard_Bar2)
end)
```

When you fix one of the bugs marked `T.known_bug`, its line turns into
`FAIL ... known bug no longer reproduces`. Change `T.known_bug(name, why, fn)` to
`T.test(name, fn)` and it becomes a normal regression test.

Useful pieces:

* **Clients**
  * `T.addon(name, opts)` and `T.suite(opts)` make clients.
  * `opts` takes `name`, `class`, `race`, `level`, `money`, `bags`, `guild`, `party`, `saved` (SavedVariables), `cvars`, `art`, `missing` and `latency`. The comment above `api.new_client` lists them all.
  * Every client in a test shares one chat bus and one clock.
* **Server packets**
  * `api.server_packet(env, "TAG", body, { via = "system"|"addon"|"whisper", chunk = n })` sends a packet. It says `HI` first if the client is not connected yet.
  * `api.connect(env)` sends the greeting alone.
  * `api.on_server(env, "lg", fn)` answers the client's `.wnl lg` on the next pump.
* **Time and chat**
  * `api.tick(env, seconds)` runs `OnUpdate` on every client and delivers chat between steps.
  * `api.pump(env)` only delivers chat.
* **Player input**
  * `env.__slash("/rp ic")` runs a slash command.
  * `api.click(frame, "RightButton")`, `api.enter(frame)` and `api.type(editbox, text)` click, hover and type.
  * `api.click_text(env, "Ready", root)` clicks the button that shows that text.
  * `api.press_escape(env)` presses Escape.
  * `api.popup_click(env, "WHICH", 1)` clicks a popup button.
* **The world**
  * `api.set_target(env, "Name" | {...})` changes the target.
  * `api.mouseover(env, ...)` puts a unit under the mouse.
  * `api.group({A, B}, "party"|"raid")` groups clients.
  * `api.add_nameplate(env, {...})` adds a nameplate.
  * `api.open_merchant`, `api.open_bank` and `api.browse_auctions` open the merchant, the bank and the auction house.
  * `api.fire(env, "EVENT", ...)` fires any event.
* **What the player sees**
  * `api.chat_text(env)` returns the chat window.
  * `api.tooltip_lines(env)` returns the tooltip.
  * `api.visible_texts(env, frame)` and `api.screen_has(env, text, frame)` read the text on screen.
  * `env.__wnl` lists the `.wnl` commands the client sent.
  * `env.__sounds`, `env.__popups` and `env.__addon_sent` record sounds, popups and addon messages.
  * `T.expect_error(env, text)` consumes an error you caused on purpose.
* **Logging out**
  * `T.relog(env)` logs out and back in.
  * It keeps SavedVariables, CVars, money, bags and the ignore list.

## What the fake client covers

* **Lua 5.0 shape**
  * `string`, `math`, `table` and `bit` hold only the 1.12 functions:
    * there is `string.gfind`, with no `gmatch` or `match`;
    * there is `math.mod`, with no `fmod`;
    * `getn` reads `t.n`, as in 5.0.
  * The WoW globals exist: `strfind`, `tinsert`, `getn`, `mod`, `format`, and `sin`/`cos` in degrees.
  * Addon code that calls a string method (`s:upper()`) fails, because 5.0 strings have no methods.
  * Names from later clients are `nil`, so feature tests take the 1.12 path. These include `hooksecurefunc`, `select`, `C_Timer` and `print`.
* **Lua 5.0 syntax**
  * `lua50_guard.lua` flags these outside comments and strings:
    * `#` and `%`;
    * `select(`;
    * `string.gmatch` and `string.match`;
    * `:match(`;
    * `...` outside a parameter list;
    * `[==[` brackets.
  * The guard is best effort.
* **Missing API**
  * Calling a global the sim does not have fails with `fake API missing: X`. The message also says whether X is a real 1.12 function (the fake needs it) or not (the addon has a bug).
* **Widgets**
  * A real 1.12 widget method the fake does not model is a silent no-op.
  * A method that does not exist in 1.12 is `nil`, as in the real client.
  * These are tracked: show/hide (with `OnShow`/`OnHide`), scripts, events, points, size, alpha, text and text colour, textures, status bars, check buttons, edit boxes (max letters, `OnTextChanged`), scroll frames and tooltips (lines live in `GameTooltipTextLeftN`).
  * `RegisterEvent` with a name that is not a 1.12 event is an error.
* **Stock UI the addons look for**
  * Frames: `UIParent`, `WorldFrame`, `Minimap`, `TargetFrame`, `GameTooltip`, `ChatFrame1..7` with their tabs, `MerchantFrame` with `MerchantItemN`, `GameMenuFrame`, `UIOptionsFrame` and `StaticPopup1`.
  * Tables and functions: `UISpecialFrames`, `StaticPopupDialogs`, `UnitPopupMenus` and the stock bag functions.
  * `ChatFrame_OnEvent` prints chat lines, so the chat filters can be tested.
* **Game state**
  * Units: `player`, `target`, `mouseover`, `pet`, `partyN` and `raidN`.
  * Money, bags, the bank, merchant (including repairs), auction house, loot, CVars (an unknown CVar errors), the ignore list, guild, map position and a controllable clock.
  * Money changed by the server (selling, repairs, buying) arrives one pump later, like the real coinage update. Pass `latency = false` to turn this off.
* **Chat bus**
  * Supports `SAY`, `CHANNEL` (custom channels with numbers; General, Trade and LocalDefense are joined at login), `WHISPER`, `PARTY`, `RAID` and `GUILD`.
  * Also supports addon messages for `PARTY`, `RAID`, `GUILD` and `BATTLEGROUND`. They are echoed to the sender, as in 1.12.
  * The server trims and collapses spaces. Turn this off with `api.reset_bus{ collapse_spaces = false, trim = false }`.
  * Lines over 255 bytes are errors, and so are raw `|` characters. So is an addon message on a channel 1.12 does not have.
* **Custom art**
  * A texture under `Interface\AddOns\` or `Interface\ClassicPlus\` loads only if the `.tga` or `.blp` exists in the repo. Pass `art = false` to test the stock fallbacks.

## Limits

* **Layout**
  * Nothing is drawn, and nothing is computed from anchors.
  * `GetLeft`, `GetTop` and `GetCenter` return what was set, or simple defaults.
  * Use visibility and text in tests, not pixel positions.
* **Hooks and engine data**
  * Stock FrameXML functions are small stand-ins that let the addons' hooks run. They are not the real code.
  * There is no Spell.dbc, item cache or combat engine. Combat-log lines are whatever text the test fires.
* **Events**
  * Events reach frames in registration order. The real client's order between addons may differ.
  * Event arguments are what the test passes.
* **Edit boxes**
  * Max letters counts UTF-8 characters.
  * Focus and keyboard input are not simulated. Set the text with `api.type`.
* **Guard and API names**
  * The Lua 5.0 guard is a scanner, not a parser. Unusual code layout can fool it.
  * The lists of real 1.12 names in `data/` come from the wenilla reference dump. They decide what "missing" means.
