-- Open Vanilla: Herald's custom bot-AI strategy "herald" (the Herald addon switches it on with
-- ".bot cmd <you> nc +custom::herald"; Herald Autopilot's API does too). Run against classicmangos
-- (the table lives in classiccharacters, made by hetzner/playerbots_db.sh); safe to run twice.
--
-- Why: the bot AI only loots corpses on its loot list, and "add all loot" (which fills that list)
-- runs at relevance 1, while "attack anything" (the next pull) runs at 5 the moment Herald has no
-- target. So he pulled the next mob before ever looting. This adds the corpses around him at 5.5,
-- before the next pull; looting itself (6 to 8) then beats the pull. With nothing to loot the line
-- fails at once and the next action runs in the same tick.
--
-- Undo: DELETE FROM classiccharacters.ai_playerbot_custom_strategy WHERE name = 'herald' AND owner = 0;
-- the table as the PlayerBots module makes it (sql/characters/ai_playerbot_custom_strategy.sql), in case
-- playerbots_db.sh hasn't run yet
CREATE TABLE IF NOT EXISTS classiccharacters.ai_playerbot_custom_strategy (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `idx` bigint(20),
  `owner` bigint(20),
  `action_line` varchar(1024) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
DELETE FROM classiccharacters.ai_playerbot_custom_strategy WHERE name = 'herald' AND owner = 0;
--
-- Rest before the next pull: the bot AI's own eating runs at 3 (below 50% health) and the next pull
-- at 5, so Herald pulled hurt or empty. These win over the pull (5) while he is below 70% health
-- (critical < 20, low 20-50, medium 50-70 in aiplayerbot.conf) or below 40% mana: eat or drink if he
-- has food or water (5.45), else sit (5.4) until he is back up; with food he eats on to 90%
-- (almost full health: 70-90), since eating is quick. Looting (6-8) still comes first.
INSERT INTO classiccharacters.ai_playerbot_custom_strategy (name, idx, owner, action_line) VALUES
  ('herald', 1, 0, 'no target>add all loot!5.5'),
  ('herald', 2, 0, 'critical health>food!5.45,sit!5.4'),
  ('herald', 3, 0, 'low health>food!5.45,sit!5.4'),
  ('herald', 4, 0, 'medium health>food!5.45,sit!5.4'),
  ('herald', 5, 0, 'almost full health>food!5.45'),
  ('herald', 6, 0, 'medium mana>drink!5.45,sit!5.4');
-- (not 'high mana': that trigger is mana below 65%, hard-coded, so he drank long before he needed to)

-- Herald's fight log and stuck log (written by the world server, playerbot/HeraldBrain.cpp in
-- realm/mangos/0020-openvanilla-herald-brain.patch; read by hetzner/herald_check.sh --score and the GM
-- console). One row per fight and per stuck step of a character Herald plays. Undo:
--   DROP TABLE classiccharacters.openvanilla_herald_fight, classiccharacters.openvanilla_herald_stuck;
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_herald_fight (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT,
  created       INT UNSIGNED NOT NULL,
  guid          INT UNSIGNED NOT NULL,
  class         TINYINT UNSIGNED NOT NULL,
  level         TINYINT UNSIGNED NOT NULL,
  map           SMALLINT UNSIGNED NOT NULL,
  zone          INT UNSIGNED NOT NULL,
  x             FLOAT NOT NULL,
  y             FLOAT NOT NULL,
  mob_entry     INT UNSIGNED NOT NULL,
  mob_level     TINYINT UNSIGNED NOT NULL,
  level_gap     TINYINT NOT NULL,
  attackers_max TINYINT UNSIGNED NOT NULL,
  hp_start      TINYINT UNSIGNED NOT NULL,
  mana_start    TINYINT UNSIGNED NOT NULL,
  hp_min        TINYINT UNSIGNED NOT NULL,
  potion        TINYINT UNSIGNED NOT NULL,
  seconds       FLOAT NOT NULL,
  outcome       VARCHAR(8) NOT NULL,
  group_size    TINYINT UNSIGNED NOT NULL,
  dps_estimate  FLOAT NOT NULL,
  PRIMARY KEY (id),
  KEY guid_created (guid, created),
  KEY created (created)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_herald_stuck (
  id       INT UNSIGNED NOT NULL AUTO_INCREMENT,
  created  INT UNSIGNED NOT NULL,
  guid     INT UNSIGNED NOT NULL,
  level    TINYINT UNSIGNED NOT NULL,
  map      SMALLINT UNSIGNED NOT NULL,
  zone     INT UNSIGNED NOT NULL,
  x        FLOAT NOT NULL,
  y        FLOAT NOT NULL,
  z        FLOAT NOT NULL,
  tier     TINYINT UNSIGNED NOT NULL,
  seconds  INT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  KEY created (created),
  KEY map_xy (map, x, y)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
-- keep 30 days
DELETE FROM classiccharacters.openvanilla_herald_fight WHERE created < UNIX_TIMESTAMP() - 30 * 86400;
DELETE FROM classiccharacters.openvanilla_herald_stuck WHERE created < UNIX_TIMESTAMP() - 30 * 86400;
