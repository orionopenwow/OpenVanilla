-- Stock classic-db rows Warfront's SQL touches that the main fixtures don't carry.
DROP TABLE IF EXISTS `battleground_template`;
CREATE TABLE `battleground_template` (
  `id` mediumint(8) unsigned NOT NULL,
  `MinPlayersPerTeam` smallint(5) unsigned NOT NULL DEFAULT '0',
  `MaxPlayersPerTeam` smallint(5) unsigned NOT NULL DEFAULT '0',
  `MinLvl` tinyint(3) unsigned NOT NULL DEFAULT '0',
  `MaxLvl` tinyint(3) unsigned NOT NULL DEFAULT '0',
  `AllianceStartLoc` mediumint(8) unsigned NOT NULL,
  `HordeStartLoc` mediumint(8) unsigned NOT NULL,
  `StartMaxDist` float NOT NULL DEFAULT '0',
  `PlayerSkinReflootId` mediumint(8) unsigned NOT NULL DEFAULT '0',
  PRIMARY KEY (`id`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;
INSERT INTO `battleground_template` VALUES (1,20,40,51,60,611,610,100,1),(2,5,10,10,60,769,770,75,0),(3,8,15,20,60,890,889,75,0);
DROP TABLE IF EXISTS `game_event`;
CREATE TABLE `game_event` (
  `entry` mediumint(8) unsigned NOT NULL,
  `schedule_type` int(11) NOT NULL DEFAULT '0',
  `occurence` bigint(20) unsigned NOT NULL DEFAULT '86400',
  `length` bigint(20) unsigned NOT NULL DEFAULT '43200',
  `holiday` mediumint(8) unsigned NOT NULL DEFAULT '0',
  `linkedTo` mediumint(8) unsigned NOT NULL DEFAULT '0',
  `description` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`entry`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;
INSERT INTO `game_event` VALUES (16,1,180,3,0,0,'Gurubashi Arena Booty Run'),(1024,1,60,1,0,0,'Hourly Bells');
