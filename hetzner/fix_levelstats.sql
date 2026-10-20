-- Fill player_levelstats for any new race/class combo that has none (e.g. Human Hunter).
-- Stats = the same class on a race that has it, shifted by the race difference measured on Warriors
-- (every vanilla race can be a Warrior). Existing rows are never touched.
INSERT IGNORE INTO player_levelstats (race, class, level, str, agi, sta, inte, spi)
SELECT pc.race, pc.class, s.level,
       GREATEST(1, s.str  + w.str  - ws.str),
       GREATEST(1, s.agi  + w.agi  - ws.agi),
       GREATEST(1, s.sta  + w.sta  - ws.sta),
       GREATEST(1, s.inte + w.inte - ws.inte),
       GREATEST(1, s.spi  + w.spi  - ws.spi)
FROM playercreateinfo pc
JOIN (SELECT class, MIN(race) AS src FROM player_levelstats GROUP BY class) pick ON pick.class = pc.class
JOIN player_levelstats s  ON s.race = pick.src AND s.class = pc.class
JOIN player_levelstats w  ON w.race = pc.race  AND w.class = 1 AND w.level = s.level
JOIN player_levelstats ws ON ws.race = pick.src AND ws.class = 1 AND ws.level = s.level;

-- Every combo in playercreateinfo should now have 60 levels of stats. This lists any that don't.
SELECT pc.race, pc.class, COUNT(ls.level) AS levels
FROM playercreateinfo pc
LEFT JOIN player_levelstats ls ON ls.race = pc.race AND ls.class = pc.class
GROUP BY pc.race, pc.class
HAVING levels < 60;
