-- Open Vanilla: player reports and moderation (world server patch realm/mangos/pending/0006-openvanilla-reports.patch,
-- Herald's bot/herald_mod.py). Run against classicmangos like the other files here; every table lives in
-- classiccharacters. Safe to run twice. Undo:
--   DROP TABLE classiccharacters.openvanilla_report, classiccharacters.openvanilla_appeal,
--              classiccharacters.openvanilla_mod_note, classiccharacters.openvanilla_mod_log;

-- One row per report. The world server writes reporter/target/category/note/client_lines/context
-- (context = JSON: zone, map, x, y, time, target_online, server_lines[{t,kind,from,to?,channel?,text}]).
-- Herald fills ai_score / ai_summary / ai_action and, on a moderator's click, action / moderator / acted.
-- status: open (new) -> triaged (Herald scored and posted it) -> acted | dismissed | escalated.
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_report (
    id            INT UNSIGNED NOT NULL AUTO_INCREMENT,
    reporter_guid INT UNSIGNED NOT NULL DEFAULT 0,
    reporter_name VARCHAR(12)  NOT NULL DEFAULT '',
    target_guid   INT UNSIGNED NOT NULL DEFAULT 0,
    target_name   VARCHAR(12)  NOT NULL DEFAULT '',
    category      VARCHAR(16)  NOT NULL DEFAULT 'other',
    note          VARCHAR(1000) NOT NULL DEFAULT '',
    client_lines  TEXT,
    context       TEXT,
    created       INT UNSIGNED NOT NULL DEFAULT 0,
    status        VARCHAR(16)  NOT NULL DEFAULT 'open',
    ai_score      TINYINT UNSIGNED NULL,
    ai_summary    VARCHAR(500) NULL,
    ai_action     VARCHAR(16)  NULL,
    action        VARCHAR(32)  NULL,
    moderator     VARCHAR(64)  NULL,
    acted         INT UNSIGNED NULL,
    PRIMARY KEY (id),
    KEY idx_status (status, created),
    KEY idx_target (target_guid, created),
    KEY idx_reporter (reporter_guid, created)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- "/appeal <text>" in game.
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_appeal (
    id      INT UNSIGNED NOT NULL AUTO_INCREMENT,
    guid    INT UNSIGNED NOT NULL DEFAULT 0,
    name    VARCHAR(12)  NOT NULL DEFAULT '',
    text    VARCHAR(400) NOT NULL DEFAULT '',
    created INT UNSIGNED NOT NULL DEFAULT 0,
    seen    TINYINT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    KEY idx_seen (seen, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ".wnl mod note <name> <text>": private moderator notes.
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_mod_note (
    id        INT UNSIGNED NOT NULL AUTO_INCREMENT,
    guid      INT UNSIGNED NOT NULL DEFAULT 0,
    name      VARCHAR(12)  NOT NULL DEFAULT '',
    moderator VARCHAR(64)  NOT NULL DEFAULT '',
    text      VARCHAR(1000) NOT NULL DEFAULT '',
    created   INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    KEY idx_guid (guid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Every moderation action the world server took: mute, auto-mute, unmute, kick, warn, spamok, and
-- "hide" (the repeat-spam filter dropped a line; moderator 'auto').
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_mod_log (
    id        INT UNSIGNED NOT NULL AUTO_INCREMENT,
    guid      INT UNSIGNED NOT NULL DEFAULT 0,
    name      VARCHAR(12)  NOT NULL DEFAULT '',
    kind      VARCHAR(16)  NOT NULL DEFAULT '',
    detail    VARCHAR(500) NOT NULL DEFAULT '',
    moderator VARCHAR(64)  NOT NULL DEFAULT '',
    created   INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    KEY idx_kind (kind, id),
    KEY idx_guid (guid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
