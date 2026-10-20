-- !Compat_112 — 1.12.1 client API the Open Vanilla web client (wenilla, 2026-10-12 build) lacks.
--
-- Rules for this file:
--   * Only functions that exist in the real 1.12.1 client's _G (benilla reference table
--     reference/1.12-globals.tsv, origin "engine") and are missing in the web client's VM
--     (probed live: ADDON_COMPAT_REPORT.md, "Engine API coverage").
--   * Never overwrite: each shim installs only when the global is nil, so the day the engine
--     implements the function natively this addon becomes a no-op.
--   * Same calling convention as 1.12: unit tokens in, 1/nil out (never true/false).
--   * Nothing from later clients (no hooksecurefunc, select, string.gmatch, GetQuestLink, ...):
--     1.12 addons feature-test those names to pick code paths, so defining them would change
--     what an unmodified addon does.
--
-- The '!' prefix sorts the folder first in the NTFS directory order the client loads in, so
-- these exist before any other addon's main chunk runs.

-- UnitCanAssist(unit1, unit2) -> 1 | nil
-- 1.12: whether unit1 could cast a beneficial spell on unit2. Used by healing, decursive and
-- click-cast addons (Clique, Decursive, healbot-style frames) to filter targets.
-- Derived from the reaction verbs the engine does implement: a unit you can attack is never
-- assistable; a friendly one (reaction >= 5, UnitIsFriend) is; neutral (yellow) is not, which
-- matches the 1.12 rule that beneficial spells need a friendly target.
if UnitCanAssist == nil then
  function UnitCanAssist(unit1, unit2)
    if not unit1 or not unit2 then return nil end
    if not UnitExists(unit1) or not UnitExists(unit2) then return nil end
    if UnitIsUnit(unit1, unit2) then return 1 end
    if UnitCanAttack(unit1, unit2) then return nil end
    if UnitIsFriend(unit1, unit2) then return 1 end
    return nil
  end
end

-- UnitIsTrivial(unit) -> 1 | nil
-- 1.12: whether the unit is "trivial" (grey) to the player: it awards no experience and its
-- level is drawn grey. The grey cut-off is the 1.12 rule (the server's Formulas.h GetGrayLevel,
-- which the client mirrors for level colouring):
--   level <= 5: none;  6..39: L - 5 - floor(L/10);  40..59: L - 1 - floor(L/5);  60: L - 9.
-- A unit of unknown level (UnitLevel == -1, the skull) is never trivial.
if UnitIsTrivial == nil then
  local function GrayLevel(level)
    if level <= 5 then return 0 end
    if level <= 39 then return level - 5 - floor(level / 10) end
    if level <= 59 then return level - 1 - floor(level / 5) end
    return level - 9
  end
  function UnitIsTrivial(unit)
    if not unit or not UnitExists(unit) then return nil end
    local level = UnitLevel(unit)
    if not level or level < 0 then return nil end
    if level <= GrayLevel(UnitLevel("player")) then return 1 end
    return nil
  end
end
