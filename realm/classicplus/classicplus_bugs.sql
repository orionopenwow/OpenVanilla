-- Open Vanilla: bug reports from the game (realm/mangos/0014-openvanilla-bug-reports.patch writes them,
-- Herald's bot/herald_bugs.py posts them to the Discord #bug-reports forum). Run against classicmangos
-- (the table lives in classiccharacters); safe to run twice. Undo:
--   DROP TABLE classiccharacters.openvanilla_bug_report;   (loses the reports)
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_bug_report (
  id         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  created    INT UNSIGNED NOT NULL,
  account    INT UNSIGNED NOT NULL,
  guid       INT UNSIGNED NOT NULL,
  name       VARCHAR(12)  NOT NULL,
  level      TINYINT UNSIGNED NOT NULL,
  class      TINYINT UNSIGNED NOT NULL,
  race       TINYINT UNSIGNED NOT NULL,
  map        SMALLINT UNSIGNED NOT NULL,
  zone       INT UNSIGNED NOT NULL,
  area       INT UNSIGNED NOT NULL,
  x          FLOAT NOT NULL,
  y          FLOAT NOT NULL,
  z          FLOAT NOT NULL,
  category   VARCHAR(16)  NOT NULL,
  text       VARCHAR(1000) NOT NULL,
  context    VARCHAR(600) NOT NULL DEFAULT '',
  posted     TINYINT UNSIGNED NOT NULL DEFAULT 0,
  discord_id BIGINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY posted (posted, id),
  KEY account (account, created)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
