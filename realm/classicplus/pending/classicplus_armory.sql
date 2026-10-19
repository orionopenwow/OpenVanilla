-- Open Vanilla: per-character armory privacy (world server patch realm/mangos/pending/0008-openvanilla-armory.patch,
-- tools/armory_export.py, docs/ARMORY.md). Run against classicmangos like the other files here; the table
-- lives in classiccharacters. Safe to run twice (MariaDB 10.0.2+: ADD COLUMN IF NOT EXISTS).
-- Undo (the setting is lost; everyone is public again):
--   ALTER TABLE classiccharacters.openvanilla_character DROP COLUMN armory, DROP COLUMN armory_key;

-- The same table classicplus_characters.sql makes (dual spec, starter pet), in case this runs first.
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_character (
  guid         INT UNSIGNED NOT NULL PRIMARY KEY COMMENT 'characters.guid',
  active_spec  TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '1 or 2',
  starter_pet  TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '1 = got the hunter starter pet'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Open Vanilla: gameplay state per character';

-- armory:     public (default: a character with no row is public too) | friends | hidden
-- armory_key: the secret in a friends-only link (?k=...), 20 characters a-z0-9, made by the world server
--             the first time a character picks "friends", replaced by ".wnl armory newlink".
ALTER TABLE classiccharacters.openvanilla_character
  ADD COLUMN IF NOT EXISTS armory     VARCHAR(8)  NOT NULL DEFAULT 'public' COMMENT 'public | friends | hidden',
  ADD COLUMN IF NOT EXISTS armory_key VARCHAR(40) NOT NULL DEFAULT ''       COMMENT 'friends-only link secret';

-- The exporter's database user: read-only on what it publishes (create it once, then grant):
--   CREATE USER IF NOT EXISTS 'armory'@'%' IDENTIFIED BY '<password>';
--   GRANT SELECT ON classiccharacters.* TO 'armory'@'%';
--   GRANT SELECT ON classicmangos.item_template TO 'armory'@'%';
--   GRANT SELECT ON classicmangos.spell_template TO 'armory'@'%';
--   GRANT SELECT ON classicmangos.openvanilla_achievement TO 'armory'@'%';
--   GRANT SELECT (id, name) ON classicrealmd.realmlist TO 'armory'@'%';
--   GRANT SELECT (id, username) ON classicrealmd.account TO 'armory'@'%';
-- hetzner/armory_cron.sh install does this for you.
