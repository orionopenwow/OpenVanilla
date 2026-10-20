# Classic+ Dynamic Feature Architecture & Addon Blueprint

## 1. Executive Summary

In traditional World of Warcraft engine builds, modifying UI features or adding new game systems typically required editing core FrameXML files, changing C++/Rust bindings, or rebuilding WebAssembly modules. 

With this **Classic+ Modular Architecture**, we decouple game modifications, features, and custom addons from engine compilation. You can build, edit, and iterate on custom Classic+ features **within the codebase** using dynamic asset layers that take effect immediately in the running game with a simple `/reload` command.

---

## 2. The 4-Tier Architectural Pipeline

```
┌────────────────────────────────────────────────────────────────────────┐
│                        4-TIER PIPELINE OVERVIEW                        │
└────────────────────────────────────────────────────────────────────────┘

 [ Tier 1: Zero-Recompile Native Layer ]
   Path: Data/Interface/AddOns/<CustomAddon>/
   • Direct filesystem discovery via Source::Dir / Chain
   • Live reloadable via in-game /reload or /cp rl
   • Full access to 1.12.1 Lua API, FrameXML hooks, and XML UI templates
                                  │
                                  ▼
 [ Tier 2: Core Bundled Registry ]
   Path: crates/benilla-app/src/bundled_addons.rs
   • Fallback registry for zero-install browser clients
   • Bundled addons run when no disk folder is found
   • Overridden automatically if a matching folder exists in Tier 1
                                  │
                                  ▼
 [ Tier 3: Lua / FrameXML Non-Invasive Hooks ]
   • Hook patterns: function hooks, RegisterEvent, SetScript("OnEvent")
   • Extends CharacterFrame, WorldMap, ActionBars without modifying stock XML
   • Persistent config via SavedVariables stored in client localStorage / WTF
                                  │
                                  ▼
 [ Tier 4: High-Performance Web & Bridge Overlays ]
   Path: web/bridge.js & web/examples/
   • Bi-directional bridge between browser canvas and WoW Lua VM
   • Enables HTML/Canvas HUDs, discord voice overlays, and hardware inputs
```

---

## 3. How to Build New Features from Scratch (Step-by-Step)

### Step 1: Create the Feature Directory
Create a new folder in `Data/Interface/AddOns/<YourAddonName>/`:
```
Data/
  └── Interface/
        └── AddOns/
              └── MyClassicPlusFeature/
                    ├── MyClassicPlusFeature.toc
                    ├── Core.lua
                    └── UI.xml
```

### Step 2: Define the Table of Contents (`.toc`)
The `.toc` file defines the addon metadata, version, saved variables, and load order:
```ini
## Interface: 11200
## Title: |cff00ff00Classic+|r My Feature
## Notes: Description of the feature for players and menus.
## Author: AdventureWorld
## Version: 1.0.0
## SavedVariables: MyFeature_Config
Core.lua
UI.xml
```

### Step 3: Implement Non-Invasive Event & Method Hooks
Instead of modifying stock Blizzard files, hook into the global environment:
```lua
-- Hooking an existing global function
local original_Function = SomeBlizzardFunction
function SomeBlizzardFunction(arg1, arg2)
    -- Run custom Classic+ logic before
    original_Function(arg1, arg2)
    -- Run custom Classic+ logic after
end

-- Listening to Game Events
local f = CreateFrame("Frame", "MyFeature_EventFrame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("UNIT_HEALTH")
f:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        -- Initialize feature
    end
end)
```

### Step 4: Live Reloading
Whenever you change files inside `Data/Interface/AddOns/`, you do **not** need to restart the server or recompile Rust/WASM. In game, simply type:
```text
/reload
```
or
```text
/cp rl
```
The Lua VM is recreated on the fly, discovering all updated scripts and XML definitions instantaneously.

---

## 4. Built-in Reference Implementation: `ClassicPlus_Core`

We created and verified the initial reference addon:
- **Location:** `Data/Interface/AddOns/ClassicPlus_Core/`
- **TOC:** [ClassicPlus_Core.toc](Data/Interface/AddOns/ClassicPlus_Core/ClassicPlus_Core.toc)
- **Logic:** [ClassicPlus_Core.lua](Data/Interface/AddOns/ClassicPlus_Core/ClassicPlus_Core.lua)
- **UI:** [ClassicPlus_UI.xml](Data/Interface/AddOns/ClassicPlus_Core/ClassicPlus_UI.xml)

### Included Capabilities:
1. **Auto-Repair:** Automatically detects merchant repair capability and repairs equipment.
2. **Auto-Sell Junk:** Scans bags on `MERCHANT_SHOW` and sells all gray items.
3. **Live Coordinates HUD:** Real-time floating coordinate frame anchored to the Minimap.
4. **Slash Command Suite:** `/cp` with toggles for `/cp junk`, `/cp repair`, `/cp coords`, and fast reload `/cp rl`.
5. **AddOns Panel Integration:** Automatically discovered and listed in the Character Select and Game Menu AddOns panels with full enable/disable control.
