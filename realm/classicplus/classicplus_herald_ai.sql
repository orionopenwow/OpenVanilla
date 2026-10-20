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
INSERT INTO classiccharacters.ai_playerbot_custom_strategy (name, idx, owner, action_line) VALUES
  ('herald', 1, 0, 'no target>add all loot!5.5');
