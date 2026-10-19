-- Open Vanilla Classic+: undo classicplus_pace.sql. Every changed value comes back from
-- openvanilla_pace_backup; the boards and dummies (and their quest links) are removed.
UPDATE creature_loot_template l JOIN openvanilla_pace_backup b ON b.what = 'quest_drop' AND b.k1 = l.entry AND b.k2 = l.item
  SET l.ChanceOrQuestChance = b.val;
UPDATE item_template i JOIN openvanilla_pace_backup b ON b.what = 'party_loot' AND b.k1 = i.entry
  SET i.Flags = i.Flags & ~2048;
UPDATE spell_template s JOIN openvanilla_pace_backup b ON b.what = 'hearthstone' AND b.k1 = s.Id
  SET s.CategoryRecoveryTime = b.val;
UPDATE spell_template s JOIN openvanilla_pace_backup b ON b.what = 'blessing' AND b.k1 = s.Id
  SET s.DurationIndex = b.val;
UPDATE creature c JOIN openvanilla_pace_backup b ON b.what = 'escort_respawn' AND b.k1 = c.guid
  SET c.spawntimesecsmin = b.val, c.spawntimesecsmax = b.val2;
DELETE FROM gameobject_questrelation WHERE id BETWEEN 990701 AND 990719;
DELETE FROM gameobject_involvedrelation WHERE id BETWEEN 990701 AND 990719;
DELETE FROM gameobject WHERE guid BETWEEN 9100701 AND 9100760;
DELETE FROM gameobject_template WHERE entry BETWEEN 990701 AND 990719;
DELETE FROM creature WHERE guid BETWEEN 9100801 AND 9100818;
DELETE FROM creature_template WHERE Entry BETWEEN 990801 AND 990803;
DROP TABLE openvanilla_pace_backup;
