-- Open Vanilla Boss Fights: the lean world of the Modes server (Duels and Boss Fights). Everything is emptied
-- except what the two modes use:
--   * the shared hangout, Gurubashi Arena: the same 70 yards round the pit as duels_lean.sql keeps;
--   * every spawn on the raid maps (Onyxia's Lair 249, Molten Core 409, Blackwing Lair 469, Zul'Gurub 309,
--     Ruins of Ahn'Qiraj 509, Temple of Ahn'Qiraj 531, Naxxramas 533): a run is the stock raid.
-- duels_lean.sql empties the raids too: hetzner/bossfights_up.sh copies them back from the live world first,
-- then runs this. Run on the Modes world database ONLY; never on the live realm's. Re-runnable.

DELETE FROM `creature` WHERE NOT (
     (`map` = 0 AND (POW(`position_x` + 13202.9, 2) + POW(`position_y` - 276.76, 2)) < 4900)
  OR `map` IN (249, 409, 469, 309, 509, 531, 533));
DELETE FROM `gameobject` WHERE NOT (
     (`map` = 0 AND (POW(`position_x` + 13202.9, 2) + POW(`position_y` - 276.76, 2)) < 4900)
  OR `map` IN (249, 409, 469, 309, 509, 531, 533));
DELETE FROM `transports`;

-- What pointed at the removed spawns (as duels_lean.sql)
DELETE FROM `creature_addon` WHERE `guid` NOT IN (SELECT `guid` FROM `creature`);
DELETE FROM `creature_movement` WHERE `Id` NOT IN (SELECT `guid` FROM `creature`);
DELETE FROM `creature_linking` WHERE `guid` NOT IN (SELECT `guid` FROM `creature`) OR `master_guid` NOT IN (SELECT `guid` FROM `creature`);
DELETE FROM `creature_battleground` WHERE `guid` NOT IN (SELECT `guid` FROM `creature`);
DELETE FROM `creature_spawn_data` WHERE `Guid` NOT IN (SELECT `guid` FROM `creature`);
DELETE FROM `creature_conditional_spawn` WHERE `Guid` NOT IN (SELECT `guid` FROM `creature`);
DELETE FROM `game_event_creature` WHERE `guid` NOT IN (SELECT `guid` FROM `creature`);
DELETE FROM `game_event_creature_data` WHERE `guid` NOT IN (SELECT `guid` FROM `creature`);
DELETE FROM `pool_creature` WHERE `guid` NOT IN (SELECT `guid` FROM `creature`);
DELETE FROM `gameobject_addon` WHERE `guid` NOT IN (SELECT `guid` FROM `gameobject`);
-- an empty gameobject_addon crashes the world server at start (duels_lean.sql, 2026-10-21): keep one row
INSERT IGNORE INTO `gameobject_addon` (`guid`) VALUES (0);
DELETE FROM `gameobject_battleground` WHERE `guid` NOT IN (SELECT `guid` FROM `gameobject`);
DELETE FROM `game_event_gameobject` WHERE `guid` NOT IN (SELECT `guid` FROM `gameobject`);
DELETE FROM `pool_gameobject` WHERE `guid` NOT IN (SELECT `guid` FROM `gameobject`);
DELETE FROM `spawn_group_spawn` WHERE `Guid` NOT IN (SELECT `guid` FROM `creature`) AND `Guid` NOT IN (SELECT `guid` FROM `gameobject`);

SELECT (SELECT COUNT(*) FROM `creature`) AS creatures_left, (SELECT COUNT(*) FROM `gameobject`) AS objects_left,
       (SELECT COUNT(*) FROM `creature` WHERE `map` IN (249, 409, 469, 309, 509, 531, 533)) AS raid_creatures;
