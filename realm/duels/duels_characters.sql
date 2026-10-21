-- Open Vanilla Duels (hetzner/duels_up.sh): the characters database's results log, written by the world
-- server (realm/mangos/0021-openvanilla-duels.patch) when a match ends. The website's ladder and feed are
-- made from it and from warfront_arena_rating. Safe to run again.
CREATE TABLE IF NOT EXISTS warfront_arena_result (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  mode VARCHAR(4) NOT NULL,
  ended INT UNSIGNED NOT NULL,
  seconds INT UNSIGNED NOT NULL DEFAULT 0,
  winner TINYINT NOT NULL,                 -- 0 or 1 (a side), 2 a draw
  score0 TINYINT UNSIGNED NOT NULL DEFAULT 0,
  score1 TINYINT UNSIGNED NOT NULL DEFAULT 0,
  team0 VARCHAR(255) NOT NULL DEFAULT '',  -- name:class:guid[:left];...
  team1 VARCHAR(255) NOT NULL DEFAULT '',
  delta0 INT NOT NULL DEFAULT 0,
  delta1 INT NOT NULL DEFAULT 0,
  rated TINYINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY ended (ended)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
