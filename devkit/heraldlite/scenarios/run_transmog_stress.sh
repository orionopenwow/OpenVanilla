#!/bin/bash
# run_transmog_stress.sh - N Herald Lite bots hammer transmog at once, then the realm is checked.
#   HL_HOST=127.0.0.1 MYSQL="mysql -uroot -p..." bash run_transmog_stress.sh [bots=8] [steps=150] [seed=1]
# Accounts HERALDC.. (password hlpass<letter>1), GM level 3; characters Tmstress<letter> are made
# on first login (HL_CREATE). Needs heraldlite built (cargo build --release) and a realm with
# OpenVanilla.Transmog = 1. MANGOS_LOG = the world server's log to scan (default /opt/mangos/logs/Server.log).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HL=${HL:-$HERE/../target/release/heraldlite}
BOTS=${1:-8}; STEPS=${2:-150}; SEED=${3:-1}
OUT=${OUT:-$(mktemp -d)}
MYSQL=${MYSQL:-mysql -uroot}
export HL_HOST=${HL_HOST:-127.0.0.1}
LOG=${MANGOS_LOG:-/opt/mangos/logs/Server.log}
LETTERS=(c d e f g h i j k l m n o p)
python3 "$HERE/transmog_stress.py" "$OUT" "$BOTS" "$STEPS" "$SEED"
before=$(wc -l < "$LOG" 2>/dev/null || echo 0)
start=$(date +%s)
pids=()
for ((b = 0; b < BOTS; b++)); do
  l=${LETTERS[$b]}; U=$(echo "$l" | tr a-z A-Z)
  HL_USER=HERALD$U HL_PASS=hlpass${l}1 HL_CHAR=Tmstress$l HL_CREATE=${HL_CREATE:-3:3} \
    "$HL" -s "$OUT/stress_$b.txt" > "$OUT/result_$b.json" 2> "$OUT/log_$b.txt" &
  pids+=($!)
done
# a "real player" running the normal checks at the same time
if [ -n "${HL_USER:-}" ]; then
  "$HL" -s "$HERE/transmog_smoke.txt" > "$OUT/result_smoke.json" 2> "$OUT/log_smoke.txt" &
  pids+=($!)
fi
for p in "${pids[@]}"; do wait "$p"; done
echo "== bots finished in $(( $(date +%s) - start ))s"
python3 - "$OUT" <<'PY'
import json, glob, sys, os
bad = 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], "result_*.json"))):
    try:
        d = json.load(open(f))
    except Exception as e:
        print("XX", os.path.basename(f), "no result:", e); bad += 1; continue
    if not d.get("scenarios"):
        print("XX", os.path.basename(f), "did not run:", "; ".join(d.get("failures", []))[:200]); bad += 1
    for sc in d.get("scenarios", []):
        ok = sc.get("fail") == 0 and not sc.get("skipped")
        bad += 0 if ok else 1
        print("ok" if ok else "XX", os.path.basename(f), sc.get("pass"), "passed", sc.get("fail"), "failed")
        for st in sc.get("steps", []):
            if not st["ok"]:
                print("     ", st["step"][:90], "->", st.get("detail", "")[:160])
sys.exit(1 if bad else 0)
PY
bots_ok=$?
echo "== server log since the start (errors mentioning transmog, crashes, asserts)"
tail -n +$((before + 1)) "$LOG" 2>/dev/null | grep -iE "transmog|assert|crash|segfault|exception" | head -20
echo "== database invariants (each line should say 0)"
$MYSQL classiccharacters -N -e "
SELECT 'outfit rows beyond the account''s unlocked slots', COUNT(*) FROM transmog_outfit o JOIN characters c ON c.guid = o.guid JOIN transmog_account a ON a.account = c.account WHERE o.id > a.outfits;
SELECT 'outfit slot rows without their outfit', COUNT(*) FROM transmog_outfit_slot s LEFT JOIN transmog_outfit o ON o.guid = s.guid AND o.id = s.id WHERE o.id IS NULL;
SELECT 'slot rows on slots that take no look', COUNT(*) FROM transmog_outfit_slot WHERE slot NOT IN (0,2,3,4,5,6,7,8,9,14,15,16,17,18);
SELECT 'accounts past 50 outfit slots', COUNT(*) FROM transmog_account WHERE outfits > 50 OR outfits < 2;
SELECT 'outfit names longer than 24 or empty', COUNT(*) FROM transmog_outfit WHERE CHAR_LENGTH(name) > 24 OR name = '';
SELECT 'custom sets past 100 per account', COUNT(*) FROM (SELECT account FROM transmog_customset GROUP BY account HAVING COUNT(*) > 100) x;
SELECT 'hunters with a non-mail look saved on armor', COUNT(*) FROM transmog_outfit_slot s JOIN characters c ON c.guid = s.guid JOIN classicmangos.item_template t ON t.entry = s.look WHERE c.class = 3 AND t.class = 4 AND t.subclass IN (1,2,4) AND t.InventoryType NOT IN (16,4,19);
SELECT 'active outfits that don''t exist', COUNT(*) FROM transmog_character t JOIN characters c ON c.guid = t.guid LEFT JOIN transmog_outfit o ON o.guid = t.guid AND o.id = t.active WHERE t.active > 0 AND o.id IS NULL;
"
echo "== results in $OUT"
exit $bots_ok
