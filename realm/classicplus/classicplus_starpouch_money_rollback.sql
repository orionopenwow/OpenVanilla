-- Open Vanilla Classic+: undo classicplus_starpouch_money.sql — the old random ranges. Run against
-- classicmangos, then restart the world server.
UPDATE item_template SET minMoneyLoot = 2500,   maxMoneyLoot = 7500   WHERE entry = 90100;
UPDATE item_template SET minMoneyLoot = 10000,  maxMoneyLoot = 20000  WHERE entry = 90101;
UPDATE item_template SET minMoneyLoot = 20000,  maxMoneyLoot = 40000  WHERE entry = 90102;
UPDATE item_template SET minMoneyLoot = 40000,  maxMoneyLoot = 70000  WHERE entry = 90103;
UPDATE item_template SET minMoneyLoot = 70000,  maxMoneyLoot = 110000 WHERE entry = 90104;
UPDATE item_template SET minMoneyLoot = 110000, maxMoneyLoot = 160000 WHERE entry = 90105;
