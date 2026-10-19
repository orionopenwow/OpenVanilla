-- Open Vanilla Classic+: undo classicplus_classquests.sql. Run against classicmangos, then restart the
-- world server. Characters keep anything they already learned. (The Aquatic Form chain fix stays:
-- it repairs classic-db for every druid.)
UPDATE quest_template SET RequiredRaces = RequiredRaces & ~64 WHERE entry IN (6064, 6084, 6085, 6086);
UPDATE quest_template SET RequiredRaces = RequiredRaces & ~128 WHERE RequiredClasses = 1024 AND RequiredRaces & 32;
DELETE FROM creature_questrelation WHERE quest BETWEEN 90601 AND 90608;
DELETE FROM creature_involvedrelation WHERE quest BETWEEN 90601 AND 90608;
DELETE FROM quest_template WHERE entry BETWEEN 90601 AND 90608;
DELETE FROM item_required_target WHERE entry BETWEEN 990611 AND 990616;
DELETE FROM item_template WHERE entry BETWEEN 990611 AND 990616;
DELETE FROM creature WHERE guid IN (9100601, 9100602);
DELETE FROM npc_trainer WHERE entry IN (990601, 990602);
DELETE FROM creature_template WHERE Entry IN (990601, 990602);
