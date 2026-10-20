-- Open Vanilla: retire the old cosmic vendor NPC (run against classicmangos; idempotent).
-- Removes creature 990001 (template, its two spawns 9100001-9100002 and its vendor list). Item
-- 990101 is kept, because players may own it: only its name and description change. Nothing else
-- is touched; old tables stay in place.
DELETE FROM creature WHERE guid IN (9100001, 9100002) AND id = 990001;
DELETE FROM npc_vendor WHERE entry = 990001;
DELETE FROM creature_template WHERE Entry = 990001;
UPDATE item_template SET name = 'Starfire Firework Crate', description = 'Violet starfire rockets.'
  WHERE entry = 990101;
