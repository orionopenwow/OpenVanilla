-- Open Vanilla Classic+: who still plays a race/class pair that is closed to new characters.
-- Read-only (characters are never deleted). Run against classicmangos (or classiccharacters).
-- Tauren Paladins (6,2) and Dwarf Shamans (3,7) left the offer with the 56-combo set; the others
-- were retired earlier. Their playercreateinfo rows stay as long as such a character exists.
SELECT CASE (race * 100 + class) WHEN 602 THEN 'Tauren Paladin' WHEN 307 THEN 'Dwarf Shaman' ELSE CONCAT(race, '/', class) END AS combo,
       COUNT(*) AS characters, MAX(level) AS highest_level
FROM classiccharacters.characters
WHERE (race, class) IN ((6,2),(3,7),(1,7),(1,11),(2,2),(2,11),(3,11),(4,2),(4,7),(5,2),(5,7),(5,11),(7,2),(7,7),(7,11),(8,2))
GROUP BY race, class ORDER BY characters DESC;
