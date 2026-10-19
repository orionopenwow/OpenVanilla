-- Open Vanilla Classic+: class and pet trainers know you learn as you level (PENDING: launch day, with
-- realm/mangos/pending 0003/0004: OpenVanilla.AutoLearn teaches every class spell and rank at level-up).
-- Run against classicmangos; idempotent. The trainer window's greeting becomes
-- "You already know everything for your level." (it still lists what the trainer teaches, all
-- greyed out once learned). The old greetings are kept in openvanilla_trainer_greeting_backup;
-- undo with classicplus_trainers_rollback.sql. Restart the world server to apply.
CREATE TABLE IF NOT EXISTS openvanilla_trainer_greeting_backup (
  Entry  INT UNSIGNED NOT NULL PRIMARY KEY,
  Text   LONGTEXT NULL                       -- NULL: the trainer had no greeting row
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Open Vanilla: trainer greetings before classicplus_trainers.sql';

-- remember what each class/pet trainer said before (first run only)
INSERT IGNORE INTO openvanilla_trainer_greeting_backup (Entry, Text)
  SELECT c.Entry, g.Text FROM creature_template c LEFT JOIN trainer_greeting g ON g.Entry = c.Entry
  WHERE (c.NpcFlags & 16) AND ((c.TrainerType = 0 AND c.TrainerClass > 0) OR c.TrainerType = 3);

REPLACE INTO trainer_greeting (Entry, Text)
  SELECT Entry, 'You already know everything for your level.' FROM openvanilla_trainer_greeting_backup;
