-- Open Vanilla Duels: the lean world. Duels is played in Gurubashi Arena (the hangout and, as map 900,
-- the matches), so the rest of the world is emptied: every creature and object spawn goes, except the
-- arena's own (70 yards around its pit) and the ones duels_world.sql adds there; the boats and zeppelins go too (they keep whole
-- continents loaded). Smaller memory and nothing out there to walk to (the hangout fences players in
-- anyway). Run on the Duels world database ONLY (hetzner/duels_up.sh); never on the live realm's.
-- Re-runnable. To undo: reinstall the world database (the Duels stack's db-init).

DELETE FROM `creature` WHERE NOT (`map` = 0 AND (POW(`position_x` + 13202.9, 2) + POW(`position_y` - 276.76, 2)) < 4900);
DELETE FROM `gameobject` WHERE NOT (`map` = 0 AND (POW(`position_x` + 13202.9, 2) + POW(`position_y` - 276.76, 2)) < 4900);
DELETE FROM `transports`;

-- What pointed at the removed spawns
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
-- The world server reads gameobject_addon without checking for an empty result (ObjectMgr::LoadGameObjects):
-- an empty table crashes it at start (2026-10-21). One row for no object (guid 0) keeps it non-empty.
INSERT IGNORE INTO `gameobject_addon` (`guid`) VALUES (0);
DELETE FROM `gameobject_battleground` WHERE `guid` NOT IN (SELECT `guid` FROM `gameobject`);
DELETE FROM `game_event_gameobject` WHERE `guid` NOT IN (SELECT `guid` FROM `gameobject`);
DELETE FROM `pool_gameobject` WHERE `guid` NOT IN (SELECT `guid` FROM `gameobject`);
DELETE FROM `spawn_group_spawn` WHERE `Guid` NOT IN (SELECT `guid` FROM `creature`) AND `Guid` NOT IN (SELECT `guid` FROM `gameobject`);

SELECT (SELECT COUNT(*) FROM `creature`) AS creatures_left, (SELECT COUNT(*) FROM `gameobject`) AS objects_left;
