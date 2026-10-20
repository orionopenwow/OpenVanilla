"""
Warfront's SQL on a throwaway MariaDB: the world and characters files apply, twice, and the
queries the world server runs (OpenVanilla/Warfront.cpp, WarfrontArena.cpp) are valid against them.

    python3 devkit/db/test_warfront_sql.py --local     a private mariadbd in a temp dir (Linux, CI)
    python3 devkit/db/test_warfront_sql.py             Docker (devkit/db/compose.yaml)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_sql as base  # noqa: E402  (start_local, start_docker, fingerprint, check, results)

ROOT = os.path.dirname(os.path.dirname(HERE))
WF = os.path.join(ROOT, "realm", "warfront")
FIX = os.path.join(HERE, "fixtures")
check = base.check


def main():
    local = "--local" in sys.argv
    db, stop = base.start_local() if local else base.start_docker("--keep" in sys.argv)
    try:
        for name in ("classicmangos", "classicrealmd", "classiccharacters"):
            db.run(f"DROP DATABASE IF EXISTS {name}; CREATE DATABASE {name} DEFAULT CHARSET utf8mb4;")
        db.run(path=os.path.join(FIX, "classicmangos.sql"), db="classicmangos")
        db.run(path=os.path.join(FIX, "warfront_extra.sql"), db="classicmangos")
        db.run(path=os.path.join(FIX, "classiccharacters.sql"), db="classiccharacters")
        world = ["warfront_kits.sql", "warfront_item_pool.sql", "warfront_world.sql"]
        for i in (1, 2):
            for f in world:
                try:
                    db.run(path=os.path.join(WF, f), db="classicmangos")
                    if i == 1:
                        check(f"{f} applies", True)
                except RuntimeError as e:
                    check(f"{f} applies (pass {i})", False, str(e))
            try:
                db.run(path=os.path.join(WF, "warfront_characters.sql"), db="classiccharacters")
                if i == 1:
                    check("warfront_characters.sql applies", True)
            except RuntimeError as e:
                check(f"warfront_characters.sql applies (pass {i})", False, str(e))
            if i == 1:
                first = base.fingerprint(db)
        second = base.fingerprint(db)
        changed = [t for t in first if first[t] != second.get(t)]
        check("every Warfront file is safe to run twice", not changed, "changed: " + ", ".join(changed))

        v = lambda q, d="classicmangos": db.value(q, d)
        kits = int(v("SELECT COUNT(DISTINCT kit) FROM warfront_kit"))
        check(f"29 kits ({kits})", kits == 29)
        thin = v("SELECT COUNT(*) FROM (SELECT kit FROM warfront_kit GROUP BY kit HAVING COUNT(*) < 16) x")
        check("every kit fills at least 16 slots", thin == "0", f"{thin} kits with fewer")
        check("no Horde paladin or Alliance shaman kit",
              v("SELECT COUNT(*) FROM warfront_kit WHERE (class=2 AND faction='Horde') OR (class=7 AND faction='Alliance')") == "0")
        check("every kit has enchants", v("SELECT COUNT(DISTINCT kit) FROM warfront_kit_enchant") == "29")
        loose = v("SELECT COUNT(*) FROM warfront_kit_enchant e LEFT JOIN warfront_enchant a ON a.slot=e.slot AND a.spell=e.spell WHERE a.spell IS NULL")
        check("every kit enchant is in the picker's enchant list", loose == "0", f"{loose} missing")
        notpool = v("SELECT COUNT(*) FROM warfront_kit k LEFT JOIN warfront_item_pool p ON p.item=k.item WHERE p.item IS NULL")
        check("every kit item is in the gear pool (so it can be swapped back)", notpool == "0", f"{notpool} missing")
        kittier = v("SELECT COUNT(*) FROM warfront_kit k JOIN warfront_item_pool p ON p.item=k.item WHERE p.tier <> 0")
        check("kit items are all tier 0", kittier == "0", f"{kittier} not")
        pool = int(v("SELECT COUNT(*) FROM warfront_item_pool"))
        check(f"the gear pool is filled ({pool} items)", pool > 1000)
        tiers = v("SELECT GROUP_CONCAT(DISTINCT tier ORDER BY tier) FROM warfront_item_pool")
        check(f"tiers 0, 2 and 3 only ({tiers})", tiers == "0,2,3")
        check("Corrupted Ashbringer and Atiesh are not in the pool",
              v("SELECT COUNT(*) FROM warfront_item_pool WHERE item IN (22691, 22589, 22630, 22631, 22632)") == "0")
        naxx = v("SELECT COUNT(*) FROM warfront_item_pool WHERE source = 'Naxxramas' AND tier <> 3")
        check("items only from Naxxramas are tier 3", naxx == "0", f"{naxx} are not")
        check("consumables shop filled", int(v("SELECT COUNT(*) FROM warfront_consumable")) >= 30)
        check("Alliance starts in Stormwind",
              v("SELECT COUNT(*) FROM playercreateinfo WHERE race IN (1,3,4,7) AND (map<>0 OR zone<>1519)") == "0")
        check("Horde starts in Orgrimmar",
              v("SELECT COUNT(*) FROM playercreateinfo WHERE race IN (2,5,6,8) AND (map<>1 OR zone<>1637)") == "0")
        check("Warsong Gulch starts at 6 a side", v("SELECT MinPlayersPerTeam FROM battleground_template WHERE id=2") == "6")
        check("Alterac Valley starts at 20 a side", v("SELECT MinPlayersPerTeam FROM battleground_template WHERE id=1") == "20")
        check("Gurubashi chest every 60 minutes", v("SELECT occurence FROM game_event WHERE entry=16") == "60")
        check("other events untouched", v("SELECT occurence FROM game_event WHERE entry=1024") == "60")
        sellable = v("""SELECT COUNT(*) FROM item_template t WHERE t.SellPrice > 0 AND (t.entry IN (SELECT item FROM warfront_item_pool)
                        OR t.entry IN (SELECT item FROM warfront_consumable) OR t.entry IN (17966, 4500, 18776, 18797, 14530, 15993, 13446, 5634))""")
        check("free items can't be sold", sellable == "0", f"{sellable} still have a price")
        check("free gear can't be disenchanted",
              v("SELECT COUNT(*) FROM item_template t JOIN warfront_item_pool p ON p.item = t.entry WHERE t.DisenchantID <> 0") == "0")

        # The world server's own queries, as written in Warfront.cpp / WarfrontArena.cpp
        c = lambda q: db.run(q, db="classiccharacters")
        w = lambda q: db.run(q, db="classicmangos")
        try:
            w("SELECT kit, class, faction, slot, item FROM warfront_kit ORDER BY kit, slot")
            w("SELECT kit, slot, spell FROM warfront_kit_enchant ORDER BY kit, slot")
            w("SELECT item, tier FROM warfront_item_pool")
            w("SELECT slot, spell FROM warfront_enchant")
            w("SELECT item, price, max_count FROM warfront_consumable")
            w("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'warfront_kit'")
            check("the server's world queries run", True)
        except RuntimeError as e:
            check("the server's world queries run", False, str(e))
        try:
            c("INSERT INTO characters (guid, account, name) VALUES (1, 10, 'Herald'), (2, 11, 'Berra') ON DUPLICATE KEY UPDATE name=VALUES(name)")
        except RuntimeError:
            pass
        try:
            c("SELECT best_rating, max_kills, gifted FROM warfront_account WHERE account = 10")
            c("INSERT INTO warfront_account (account, best_rating, max_kills) VALUES (10, 0, 12) ON DUPLICATE KEY UPDATE max_kills = GREATEST(max_kills, VALUES(max_kills))")
            c("INSERT INTO warfront_account (account, best_rating, max_kills) VALUES (10, 0, 5) ON DUPLICATE KEY UPDATE max_kills = GREATEST(max_kills, VALUES(max_kills))")
            check("account kills only go up", db.value("SELECT max_kills FROM warfront_account WHERE account=10", "classiccharacters") == "12")
            c("UPDATE warfront_account SET gifted = 1 WHERE account = 10")
            check("the welcome gift is marked per account", db.value("SELECT gifted FROM warfront_account WHERE account=10", "classiccharacters") == "1")
            c("SELECT 1 FROM warfront_character WHERE guid = 1")
            c("INSERT IGNORE INTO warfront_character (guid, welcomed, created) VALUES (1, 1, 1700000000)")
            c("INSERT IGNORE INTO warfront_character (guid, welcomed, created) VALUES (1, 1, 1700000000)")
            c("SELECT COUNT(*) FROM warfront_shared_set WHERE account = 10 AND hidden = 0")
            c("INSERT INTO warfront_shared_set (owner_guid, owner_name, account, class, spec, name, items, votes, reports, hidden, created) "
              "VALUES (1, 'Herald', 10, 1, 'PvP', 'Big Hits', '0:16478,15:19364', 0, 0, 0, 1700000000)")
            sid = db.value("SELECT MAX(id) FROM warfront_shared_set WHERE account = 10", "classiccharacters")
            c("SELECT id, votes, owner_name, spec, name, items FROM warfront_shared_set WHERE class = 1 AND hidden = 0 ORDER BY votes DESC, id DESC LIMIT 15")
            c("SELECT id, votes, owner_name, spec, name, items FROM warfront_shared_set WHERE class = 1 AND hidden = 0 AND spec = 'PvP' ORDER BY votes DESC, id DESC LIMIT 15")
            c(f"SELECT account, votes FROM warfront_shared_set WHERE id = {sid} AND hidden = 0")
            c(f"SELECT 1 FROM warfront_set_vote WHERE set_id = {sid} AND account = 11")
            c(f"INSERT IGNORE INTO warfront_set_vote (set_id, account) VALUES ({sid}, 11)")
            c(f"UPDATE warfront_shared_set SET votes = votes + 1 WHERE id = {sid}")
            for acct in (11, 12, 13):
                c(f"INSERT IGNORE INTO warfront_set_report (set_id, account) VALUES ({sid}, {acct})")
                c(f"UPDATE warfront_shared_set SET reports = reports + 1, hidden = (reports >= 3) WHERE id = {sid}")
                if acct == 12:
                    check("two reports leave a set visible", db.value(f"SELECT hidden FROM warfront_shared_set WHERE id={sid}", "classiccharacters") == "0")
            check("three reports hide a set", db.value(f"SELECT hidden FROM warfront_shared_set WHERE id={sid}", "classiccharacters") == "1")
            c(f"SELECT class, items FROM warfront_shared_set WHERE id = {sid} AND hidden = 0")
            # arena
            c("SELECT rating FROM warfront_arena_rating WHERE guid = 1 AND bracket = 2")
            for r, won in ((1516, 1), (1500, 0)):
                c("INSERT INTO warfront_arena_rating (guid, bracket, rating, best, wins, losses) VALUES (1, 2, %d, %d, %d, %d) "
                  "ON DUPLICATE KEY UPDATE rating = VALUES(rating), best = GREATEST(best, VALUES(rating)), wins = wins + VALUES(wins), losses = losses + VALUES(losses)"
                  % (r, r, won, 1 - won))
            row = db.value("SELECT CONCAT(rating, ',', best, ',', wins, ',', losses) FROM warfront_arena_rating WHERE guid=1 AND bracket=2", "classiccharacters")
            check(f"rating, best and the win/loss count add up ({row})", row == "1500,1516,1,1")
            c("UPDATE warfront_account a JOIN characters c ON c.account = a.account SET a.best_rating = GREATEST(a.best_rating, 1516) WHERE c.guid = 1")
            check("the account's best rating follows", db.value("SELECT best_rating FROM warfront_account WHERE account=10", "classiccharacters") == "1516")
            best = db.value("SELECT MAX(r.best) FROM warfront_arena_rating r JOIN characters c ON c.guid = r.guid WHERE c.account = 10", "classiccharacters")
            check(f"best rating per account ({best})", best == "1516")
            c("SELECT c.name, r.rating FROM warfront_arena_rating r JOIN characters c ON c.guid = r.guid WHERE r.bracket = 2 ORDER BY r.rating DESC LIMIT 10")
            check("the server's characters queries run", True)
        except RuntimeError as e:
            check("the server's characters queries run", False, str(e))
    finally:
        stop()
    bad = [r for r in base.results if not r[1]]
    print(f"\n{len(base.results) - len(bad)} passed, {len(bad)} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
