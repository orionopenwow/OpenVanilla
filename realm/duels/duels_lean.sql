-- Open Vanilla Duels: the lean world. Duels is played in the Lion's Pride Inn and the arena, so the
-- rest of the world is emptied: every creature and object spawn goes, except the inn's own (40 yards
-- around it) and the ones duels_world.sql adds there; the boats and zeppelins go too (they keep whole
-- continents loaded). Smaller memory and nothing out there to walk to (the hangout fences players in
-- anyway). Run on the Duels world database ONLY (hetzner/duels_up.sh); never on the live realm's.
-- Re-runnable. To undo: reinstall the world database (the Duels stack's db-init).

DELETE FROM `creature` WHERE NOT (`map` = 0 AND (POW(`position_x` + 9464, 2) + POW(`position_y` - 14, 2)) < 1600);
DELETE FROM `gameobject` WHERE NOT (`map` = 0 AND (POW(`position_x` + 9464, 2) + POW(`position_y` - 14, 2)) < 1600);
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
DELETE FROM `gameobject_battleground` WHERE `guid` NOT IN (SELECT `guid` FROM `gameobject`);
DELETE FROM `game_event_gameobject` WHERE `guid` NOT IN (SELECT `guid` FROM `gameobject`);
DELETE FROM `pool_gameobject` WHERE `guid` NOT IN (SELECT `guid` FROM `gameobject`);
DELETE FROM `spawn_group_spawn` WHERE `Guid` NOT IN (SELECT `guid` FROM `creature`) AND `Guid` NOT IN (SELECT `guid` FROM `gameobject`);

SELECT (SELECT COUNT(*) FROM `creature`) AS creatures_left, (SELECT COUNT(*) FROM `gameobject`) AS objects_left;
