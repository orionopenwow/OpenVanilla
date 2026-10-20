-- Open Vanilla: the World channel and the Discord bridge (world server patch
-- realm/mangos/pending/0007-openvanilla-world-channel.patch, Herald's bot/herald_bridge.py, docs/DISCORD_BRIDGE.md).
-- Run against classicmangos like the other files here; every table lives in classiccharacters.
-- Safe to run twice. Undo:
--   DROP TABLE classiccharacters.openvanilla_world_log, classiccharacters.openvanilla_world_pref,
--              classiccharacters.openvanilla_guild_bridge, classiccharacters.openvanilla_guild_link_code;

-- Every World line (and every line of a guild linked to Discord), newest 1,000 kept: the world server
-- trims the ring every 10 inserts (at most 1,009 rows). guid 0 = a line that came from Discord (Herald skips those).
-- class = the character's class id (1 Warrior .. 11 Druid; 0 for Discord); guild 0 = World.
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_world_log (
    id       INT UNSIGNED NOT NULL AUTO_INCREMENT,
    guid     INT UNSIGNED NOT NULL DEFAULT 0,
    name     VARCHAR(32)  NOT NULL DEFAULT '',
    class    TINYINT UNSIGNED NOT NULL DEFAULT 0,
    guild    INT UNSIGNED NOT NULL DEFAULT 0,
    text     VARCHAR(255) NOT NULL DEFAULT '',
    created  INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    KEY idx_guild (guild, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ".wnl worldoff": the character stays out of World across logins (row deleted by ".wnl worldon").
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_world_pref (
    guid  INT UNSIGNED NOT NULL,
    off   TINYINT UNSIGNED NOT NULL DEFAULT 1,
    PRIMARY KEY (guid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Guilds whose chat is linked to a Discord channel. Herald writes it (after the officer's in-game
-- confirmation below); the world server re-reads the guild ids once a minute and logs those guilds' chat.
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_guild_bridge (
    guildid          INT UNSIGNED NOT NULL,
    discord_channel  BIGINT UNSIGNED NOT NULL,
    linked_by        VARCHAR(64) NOT NULL DEFAULT '',
    created          INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (guildid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ".wnl guildlink <code>" by a guild master or officer (rank 0/1) in game; Herald matches the code it
-- gave on Discord ("/guild discord #channel"), writes openvanilla_guild_bridge and deletes the row.
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_guild_link_code (
    code     CHAR(6) NOT NULL,
    guildid  INT UNSIGNED NOT NULL,
    guid     INT UNSIGNED NOT NULL,
    name     VARCHAR(12) NOT NULL DEFAULT '',
    created  INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
