-- Open Vanilla Classic+: undo classicplus_trainers.sql — the trainers' own greetings back. Run against
-- classicmangos, then restart the world server.
DELETE g FROM trainer_greeting g JOIN openvanilla_trainer_greeting_backup b ON b.Entry = g.Entry WHERE b.Text IS NULL;
REPLACE INTO trainer_greeting (Entry, Text) SELECT Entry, Text FROM openvanilla_trainer_greeting_backup WHERE Text IS NOT NULL;
