-- Open Vanilla Classic+: Star Pouches pay a fixed sum (PENDING: launch day, after classicplus_starpouch.sql).
-- Run against classicmangos; idempotent. Each pouch pays the middle of its old range, every time
-- (minMoneyLoot = maxMoneyLoot); the potions, scroll, the world-drop green and the 25% chance of a
-- second green are unchanged. A restart of the world server applies it (item_template is cached).
-- Undo: classicplus_starpouch_money_rollback.sql.
--   levels  2-10   50 s        (was 25-75 s)
--   levels 11-20   1 g 50 s    (was 1-2 g)
--   levels 21-30   3 g         (was 2-4 g)
--   levels 31-40   5 g 50 s    (was 4-7 g)
--   levels 41-50   9 g         (was 7-11 g)
--   levels 51-60   13 g 50 s   (was 11-16 g)
UPDATE item_template SET minMoneyLoot = 5000,   maxMoneyLoot = 5000   WHERE entry = 90100;
UPDATE item_template SET minMoneyLoot = 15000,  maxMoneyLoot = 15000  WHERE entry = 90101;
UPDATE item_template SET minMoneyLoot = 30000,  maxMoneyLoot = 30000  WHERE entry = 90102;
UPDATE item_template SET minMoneyLoot = 55000,  maxMoneyLoot = 55000  WHERE entry = 90103;
UPDATE item_template SET minMoneyLoot = 90000,  maxMoneyLoot = 90000  WHERE entry = 90104;
UPDATE item_template SET minMoneyLoot = 135000, maxMoneyLoot = 135000 WHERE entry = 90105;
