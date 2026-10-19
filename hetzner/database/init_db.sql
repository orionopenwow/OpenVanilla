-- ==============================================================================
-- Open Vanilla Production Database Initialization (Hetzner VPS)
-- ==============================================================================

CREATE DATABASE IF NOT EXISTS `classicrealmd` DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS `classiccharacters` DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS `classicmangos` DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;

-- Dedicated DB user for Open Vanilla server services
CREATE USER IF NOT EXISTS 'openvanilla'@'localhost' IDENTIFIED BY 'CHANGE_ME_DB_PASSWORD';
GRANT ALL PRIVILEGES ON `classicrealmd`.* TO 'openvanilla'@'localhost';
GRANT ALL PRIVILEGES ON `classiccharacters`.* TO 'openvanilla'@'localhost';
GRANT ALL PRIVILEGES ON `classicmangos`.* TO 'openvanilla'@'localhost';
FLUSH PRIVILEGES;

-- Ensure realmlist points to openvanilla.app as a PvE (Normal) realm
USE `classicrealmd`;

-- Delete any existing default realm row to prevent duplicates
DELETE FROM `realmlist` WHERE `id` = 1;

-- Insert the 1 dedicated cloud realm: Vanilla Remastered
-- icon: 0 = Normal (PvE), realmflags: 0 = normal, timezone: 1 = Development/US
INSERT INTO `realmlist` (`id`, `name`, `address`, `port`, `icon`, `realmflags`, `timezone`, `allowedSecurityLevel`, `population`, `realmbuilds`)
VALUES (1, 'Vanilla Remastered', 'openvanilla.app', 8085, 0, 0, 1, 0, 0, '5875');
