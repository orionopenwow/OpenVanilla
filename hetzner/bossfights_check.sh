#!/usr/bin/env bash
# Boss Fights self-test: two test accounts play the whole mode on the Modes world server (the Duels stack), with
# no one at a keyboard, and the result is published for anyone to read (no secrets, no addresses).
#
#   bash hetzner/bossfights_check.sh            run it now (as root, on the server); exit 0 when everything passed
#   bash hetzner/bossfights_check.sh --watch on|off
#                                               a systemd timer: every 2 hours (and once after every
#                                               "bossfights_up.sh update", which starts it)
#   bash hetzner/bossfights_up.sh selftest on|off|now   the same, with the world server's settings
#
# What it does:
#   1. Waits for the Modes world server; checks OpenVanilla.BossFights = 1 and .SelfTest = 1 (bossfights_up.sh
#      selftest on sets it: test accounts get their own queue, test commands and no place on the website).
#   2. Makes or repairs its two game accounts, BFTEST1 and BFTEST2 (GM level 0), straight in the Modes realm's
#      own account table. Random passwords, kept in /etc/openvanilla-bossfights-test.env (mode 600), never
#      printed. Nothing is made on the live realm or on any public sign-in page.
#   3. The website's sign-in path, from inside the server: a guest of the Modes realm service (made once by this
#      script, then resumed with its key from the same file) asks /api/play, which must name the realm realmd
#      shows (otherwise every player sees the realm list). And https://<bossfights domain>/ must open in Boss
#      Fights (a redirect to ?mode=boss).
#   4. Builds Herald Lite when its source changed (devkit/heraldlite, Docker, ~1 min), then runs
#      devkit/heraldlite/scenarios/bossfights_selftest.txt in direct mode on the stack's own network: login,
#      hangout, fence, waiting line, the pop, one new copy of Onyxia's Lair for the two, a wipe, the kill, the
#      clear, tier 2, the refresh in the hangout, a second run in a different copy, the leaver lock.
#      Then, when the server has bot fill on (OpenVanilla.BossFights.BotFill = 1, realm/mangos/0054),
#      devkit/heraldlite/scenarios/bossfights_botfill.txt: the first account alone in a raid of five with bots=1,
#      four bots come, one copy of Onyxia's Lair for the five, the kill, the end, and no bot left online.
#   5. Reads the database: the runs' result rows (marked test), nothing in "raids now", nothing of the test
#      characters in the website's bossfights_live.json; with bot fill, the bot run's row (4 bots) and no fill
#      bot still logged in.
#   6. Publishes the report: /opt/openvanilla-herald/public/bossfights_selftest.json, served at
#      https://openvanilla.app/community/bossfights_selftest.json (steps, pass/fail, timings, the copies' ids,
#      versions). Each run adds a line to /opt/openvanilla-bossfights/selftest-history.tsv.
set -uo pipefail
S=${OW_DUELS_DIR:-/opt/wenilla-duels}          # the Duels stack (duels_up.sh), where Boss Fights runs
DCP=/opt/openvanilla-duels
BCP=/opt/openvanilla-bossfights
LIVE_CP=/opt/openvanilla-classicplus
PUB=${OW_PUB:-/opt/openvanilla-herald/public}
ENVF=/etc/openvanilla-bossfights-test.env
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$LIVE_CP/repo/devkit/heraldlite; [ -d "$SRC" ] || SRC=$HERE/devkit/heraldlite
SCN=$SRC/scenarios/bossfights_selftest.txt
SCN_BOTS=$SRC/scenarios/bossfights_botfill.txt   # patch 0054: bot fill, when the server has it on
BIN=$BCP/bin/heraldlite
OUT=$BCP/selftest-last.json                    # Herald Lite's own report (root only: it names the accounts)
REPORT=$PUB/bossfights_selftest.json
HIST=$BCP/selftest-history.tsv
UNIT=openvanilla-bossfights-selftest
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
mkdir -p "$BCP" "$PUB"

if [ "${1:-}" = "--watch" ]; then
  case "${2:-}" in
  on)
    cat > /etc/systemd/system/$UNIT.service <<U
[Unit]
Description=Open Vanilla Boss Fights: the self-test (two test accounts play the mode)
After=docker.service
[Service]
Type=oneshot
TimeoutStartSec=1800
ExecStart=/bin/bash $LIVE_CP/repo/hetzner/bossfights_check.sh
U
    cat > /etc/systemd/system/$UNIT.timer <<U
[Unit]
Description=Open Vanilla Boss Fights: the self-test, every 2 hours
[Timer]
OnBootSec=20min
OnUnitActiveSec=2h
RandomizedDelaySec=5min
[Install]
WantedBy=timers.target
U
    systemctl daemon-reload && systemctl enable --now $UNIT.timer >/dev/null
    echo "self-test: every 2 hours (systemctl list-timers $UNIT.timer); report: $REPORT" ;;
  off)
    systemctl disable --now $UNIT.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/$UNIT.timer /etc/systemd/system/$UNIT.service
    systemctl daemon-reload; echo "self-test timer off" ;;
  *) echo "usage: $0 --watch on|off"; exit 2 ;;
  esac
  exit 0
fi

# one run at a time (the timer and a hand run, or an update's run)
exec 9> "$BCP/.selftest.lock"
flock -n 9 || { echo "a self-test is already running"; exit 0; }

T0=$(date +%s)
CHECKS=$BCP/.selftest-checks.tsv; : > "$CHECKS"
fails=0
ok()   { printf '  \033[1;32mPASS\033[0m %s\n' "$1"; printf 'pass\t%s\t%s\n' "$1" "${2:-}" >> "$CHECKS"; }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; printf 'fail\t%s\t%s\n' "$1" "${2:-}" >> "$CHECKS"; fails=$((fails + 1)); }
skip() { printf '  \033[1;33mSKIP\033[0m %s\n' "$1"; printf 'skip\t%s\t%s\n' "$1" "${2:-}" >> "$CHECKS"; }

# The world server's database login (duels_up.sh keeps it in $DCP/.dbinfo, mode 600). Never printed.
dvol() { docker volume ls -q --filter "label=com.docker.compose.project=owduels" --filter "label=com.docker.compose.volume=$1" | head -1; }
dbinfo() {
  if [ ! -s "$DCP/.dbinfo" ]; then
    local CFG; CFG=$(dvol config); [ -n "$CFG" ] || return 1
    ( umask 077; docker run --rm -v "$CFG":/c:ro debian:bookworm-slim sh -c 'grep -i "^WorldDatabaseInfo" /c/mangosd.conf' | cut -d'"' -f2 > "$DCP/.dbinfo" )
  fi
  cat "$DCP/.dbinfo"
}
sqle() {  # sqle DATABASE "STATEMENT"   (tab-separated rows, no header)
  (cd "$S" && docker compose exec -T -e C="$(dbinfo)" mariadb sh -c 'U=$(echo "$C" | cut -d";" -f3); W=$(echo "$C" | cut -d";" -f4); MYSQL_PWD="$W" exec mariadb -N -u"$U" "$@"' sh "$1" -e "$2") 2>/dev/null
}
conf() {  # conf KEY: its value in the Modes world server's mangosd.conf
  local CFG; CFG=$(dvol config); [ -n "$CFG" ] || return 0
  docker run --rm -v "$CFG":/c:ro debian:bookworm-slim sh -c "grep -h '^$1 *=' /c/mangosd.conf | tail -1 | sed 's/^[^=]*= *//; s/\"//g'"
}

publish() {  # the public report, from Herald Lite's and the checks above (sanitized), and the history line
  python3 - "$OUT" "$CHECKS" "$REPORT" "$HIST" "$T0" "$(date +%s)" "${BF_USER1:-}" "${BF_USER2:-}" "${BF_CHAR1:-}" "${BF_CHAR2:-}" \
           "$(git -C "$LIVE_CP/repo" rev-parse --short HEAD 2>/dev/null || echo unknown)" "${IMAGE_ID:-unknown}" <<'PY'
import json, os, re, sys, time
out, checks, report, hist, t0, t1, u1, u2, c1, c2, commit, image = sys.argv[1:13]
t0, t1 = int(t0), int(t1)
try:
    hl = json.load(open(out))
except Exception:
    hl = {}
secrets = [s for s in (u1, u2, c1, c2) if s]
def clean(text, n=200):
    text = str(text or "")
    for s, r in zip((u1, u2, c1, c2), ("account A", "account B", "Raider A", "Raider B")):
        if s:
            text = re.sub(re.escape(s), r, text, flags=re.I)
    text = re.sub(r"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b", "<address>", text)       # IPv4
    text = re.sub(r"\b[0-9a-f]{0,4}(?::[0-9a-f]{0,4}){2,7}\b", "<address>", text, flags=re.I)  # IPv6
    text = re.sub(r"(?i)(pass(word)?|key|token|secret)\S*\s*[=:]\s*\S+", r"\1=<hidden>", text)
    return text[:n]
steps = []
for sc in hl.get("scenarios", []):
    for st in sc.get("steps", []):
        steps.append({"line": st.get("line"), "client": "A" if st.get("client") == "a" else "B",
                      "step": clean(st.get("step"), 140), "ok": bool(st.get("ok")), "skipped": bool(st.get("skipped")),
                      "ms": st.get("ms", 0), "detail": clean(st.get("detail"))})
vars_ = hl.get("vars", {})
def field(line, key):
    m = re.search(r"(?:^|,)" + re.escape(key) + r"=([^,]*)", line or "")
    return m.group(1) if m else None
def num(v):
    try: return int(v)
    except Exception: return None
runs = []
for tag, key in (("run 1 (tier 1)", "r1"), ("run 2 (tier 2)", "r2")):
    a, b = vars_.get(key + "_a"), vars_.get(key + "_b")
    if a or b:
        runs.append({"run": tag, "run_id": num(field(a, "run")), "copy_a": num(field(a, "inst")), "copy_b": num(field(b, "inst")),
                     "map": num(field(a, "rmap")), "size": num(field(a, "size")), "tier": num(field(a, "tier"))})
# the bot-filled run (patch 0054): one person and four bots, all in one copy
bf = vars_.get("bf_r")
if bf:
    runs.append({"run": "bot fill (1 person, 4 bots)", "run_id": num(field(bf, "run")), "copy_a": num(field(bf, "inst")),
                 "map": num(field(bf, "rmap")), "size": num(field(bf, "size")), "tier": num(field(bf, "tier")),
                 "bots": num(field(bf, "bots")), "bots_in_copy": num(field(bf, "botsin"))})
checks_ = []
for l in open(checks):
    f = l.rstrip("\n").split("\t") + ["", "", ""]
    if f[0]:
        checks_.append({"result": f[0], "check": clean(f[1], 160), "detail": clean(f[2])})
hl_fail = int(hl.get("fail", 0) or 0) if hl else 1
ck_fail = sum(1 for c in checks_ if c["result"] == "fail")
skipped = sum(1 for s in steps if s["skipped"]) + sum(1 for c in checks_ if c["result"] == "skip")
passed = sum(1 for s in steps if s["ok"] and not s["skipped"]) + sum(1 for c in checks_ if c["result"] == "pass")
failures = [clean(f, 240) for f in hl.get("failures", [])] + [c["check"] + (": " + c["detail"] if c["detail"] else "") for c in checks_ if c["result"] == "fail"]
rep = {
    "what": "Boss Fights self-test: two test accounts queue, wait, pop into their own copy of Onyxia's Lair, wipe, kill the boss, clear, refresh in the hangout, run again in a new copy, and leave early; then (bot fill on) one account alone gets four bots, clears, and the bots log out",
    "updated": t1, "started": t0, "seconds": t1 - t0,
    "ok": bool(hl) and hl_fail == 0 and ck_fail == 0 and not hl.get("exit"),
    "pass": passed, "fail": hl_fail + ck_fail, "skipped": skipped,
    "failures": failures[:40],
    "runs": runs,
    "versions": {"repo": commit, "world_server_image": image[:19], "heraldlite": hl.get("version", "")},
    "timings_ms": {"herald_lite": hl.get("ms", 0)},
    "checks": checks_,
    "steps": steps,
}
tmp = report + ".tmp"
with open(tmp, "w") as fh:
    json.dump(rep, fh, separators=(",", ":"))
os.chmod(tmp, 0o644)
os.replace(tmp, report)
r1 = runs[0] if runs else {}
r2 = runs[1] if len(runs) > 1 else {}
with open(hist, "a") as fh:
    fh.write("\t".join(str(x) for x in (time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(t1)), "ok" if rep["ok"] else "FAIL", rep["pass"],
             rep["fail"], rep["skipped"], t1 - t0, r1.get("copy_a"), r2.get("copy_a"), commit)) + "\n")
print(("ALL PASSED" if rep["ok"] else "FAILED") + f": {rep['pass']} passed, {rep['fail']} failed, {rep['skipped']} skipped, {t1 - t0} s")
for f in failures[:15]:
    print("  - " + f)
PY
}
finish() { publish; [ "$fails" -eq 0 ] && [ "${HL_RC:-1}" -eq 0 ]; exit $?; }
: > "$OUT"

echo "== 1/6 the Modes world server"
[ -e "$S/.env" ] || { bad "no Duels stack at $S (bash hetzner/duels_up.sh install)"; finish; }
MS=$(cd "$S" && docker compose ps -q mangosd)
for _ in $(seq 1 90); do
  h=$(docker inspect -f '{{.State.Health.Status}}' "$MS" 2>/dev/null || echo none)
  [ "$h" = healthy ] && break; sleep 10; MS=$(cd "$S" && docker compose ps -q mangosd)
done
[ "$h" = healthy ] && ok "world server up" || { bad "world server not healthy ($h)"; finish; }
IMAGE_ID=$(docker inspect -f '{{.Image}}' "$MS" 2>/dev/null | sed 's/^sha256://'); export IMAGE_ID
[ "$(conf OpenVanilla.BossFights)" = 1 ] && ok "Boss Fights on" || { bad "OpenVanilla.BossFights isn't 1 (bash hetzner/bossfights_up.sh enable)"; finish; }
[ "$(conf OpenVanilla.BossFights.SelfTest)" = 1 ] && ok "self-test settings on" \
  || { bad "OpenVanilla.BossFights.SelfTest isn't 1 (bash hetzner/bossfights_up.sh selftest on)"; finish; }
TA=$(conf OpenVanilla.BossFights.TestAccounts); [ -n "$TA" ] || TA="BFTEST*"
sqle classiccharacters "SELECT test FROM bossfights_result LIMIT 0" >/dev/null 2>&1 && ok "results table has the test column" \
  || bad "bossfights_result has no test column (bash hetzner/bossfights_up.sh update)"

echo "== 2/6 the test accounts"
if [ ! -s "$ENVF" ]; then
  ( umask 077
    printf 'BF_USER1=BFTEST1\nBF_PASS1=%s\nBF_CHAR1=Raidcheck\nBF_USER2=BFTEST2\nBF_PASS2=%s\nBF_CHAR2=Raidprobe\n' \
      "$(openssl rand -hex 8 | tr a-f A-F)" "$(openssl rand -hex 8 | tr a-f A-F)" > "$ENVF" )
fi
chmod 600 "$ENVF"
set -a
# shellcheck disable=SC1090
. "$ENVF"
set +a
# the names must be test accounts by the server's own rule (OpenVanilla.BossFights.TestAccounts)
python3 - "$TA" "$BF_USER1" "$BF_USER2" <<'PY' && ok "both accounts are test accounts by the server's rule ($TA)" || bad "BF_USER1/2 don't match OpenVanilla.BossFights.TestAccounts ($TA)"
import sys
rule, names = sys.argv[1].upper().split(), [n.upper() for n in sys.argv[2:]]
def m(n): return any((r.endswith("*") and len(r) > 1 and n.startswith(r[:-1])) or r == n for r in rule)
sys.exit(0 if all(m(n) for n in names) else 1)
PY
acct() {  # acct NAME PASSWORD: make or repair (SRP6 verifier from the password, GM 0, unlocked); never printed
  local SV
  SV=$(OV_U="$1" OV_P="$2" python3 - <<'PY'
import hashlib, os
N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
salt = os.urandom(32)
h1 = hashlib.sha1(f"{os.environ['OV_U'].upper()}:{os.environ['OV_P'].upper()}".encode()).digest()
x = int.from_bytes(hashlib.sha1(salt[::-1] + h1).digest(), "little")
print(salt.hex().upper(), pow(7, x, N).to_bytes(32, "big").hex().upper())
PY
)
  sqle classicrealmd "INSERT INTO account (username, gmlevel, v, s) VALUES (UPPER('$1'), 0, '${SV#* }', '${SV%% *}')
    ON DUPLICATE KEY UPDATE gmlevel = 0, locked = 0, v = VALUES(v), s = VALUES(s)" >/dev/null \
    || sqle classicrealmd "INSERT INTO account (username, gmlevel, v, s) VALUES (UPPER('$1'), 0, '${SV#* }', '${SV%% *}')
    ON DUPLICATE KEY UPDATE gmlevel = 0, v = VALUES(v), s = VALUES(s)" >/dev/null
}
for i in 1 2; do
  u=BF_USER$i; p=BF_PASS$i
  [[ "${!u}" =~ ^[A-Za-z0-9_]{3,16}$ ]] || { bad "account $i: bad name in $ENVF"; continue; }
  acct "${!u}" "${!p}" && [ "$(sqle classicrealmd "SELECT COUNT(*) FROM account WHERE username = UPPER('${!u}') AND gmlevel = 0")" = 1 ] \
    && ok "test account $i ready" || bad "test account $i could not be written"
done

echo "== 3/6 the website's sign-in path (no realm list)"
NET=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$MS" | grep -v '^wenilla-realm_' | head -1)
RC=$(cd "$S" && docker compose ps -q realm)
RIP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$RC" 2>/dev/null)
DOMAIN=$(grep '^REALM_DOMAIN=' "$S/.env" | cut -d= -f2 | tr -d '"\r')
REALMD_NAME=$(sqle classicrealmd "SELECT name FROM realmlist WHERE id = 1" | head -1)
if [ -z "$RIP" ] || [ -z "$DOMAIN" ]; then
  skip "/api/play realm name" "the realm service's address or domain not found"
else
  PLAY=$(RIP="$RIP" DOMAIN="$DOMAIN" ENVF="$ENVF" python3 - <<'PY'
import http.client, json, os, re
rip, dom, envf = os.environ["RIP"], os.environ["DOMAIN"], os.environ["ENVF"]
key = os.environ.get("BF_GUEST_KEY", "")
jar = {}
if key:
    jar["wr_guest"] = key
def req(method, path, body=None, extra=None):
    c = http.client.HTTPConnection(rip, 8090, timeout=20)
    h = {"Host": dom, "User-Agent": "OpenVanilla-selftest", "X-Real-IP": "127.0.0.1", "X-Forwarded-For": "127.0.0.1"}
    if jar:
        h["Cookie"] = "; ".join(f"{k}={v}" for k, v in jar.items())
    h.update(extra or {})
    c.request(method, path, body=body, headers=h)
    r = c.getresponse()
    data = r.read()
    for k, v in r.getheaders():
        if k.lower() == "set-cookie":
            m = re.match(r"\s*([^=;]+)=([^;]*)", v)
            if m:
                if m.group(2):
                    jar[m.group(1)] = m.group(2)
                else:
                    jar.pop(m.group(1), None)
    return r.status, data
try:
    st, _ = req("POST", "/auth/guest", body=b"", extra={"Origin": f"https://{dom}", "Sec-Fetch-Site": "same-origin",
                                                       "Content-Type": "application/x-www-form-urlencoded"})
    if st not in (200, 302, 303) or not any(k for k in jar if k != "wr_guest"):
        print(f"ERR guest sign-in answered {st}"); raise SystemExit
    if jar.get("wr_guest") and jar["wr_guest"] != key:
        # keep the guest this script made, to resume it next time (one guest, not one a run)
        lines = [l for l in open(envf).read().splitlines() if not l.startswith("BF_GUEST_KEY=")]
        lines.append("BF_GUEST_KEY=" + jar["wr_guest"])
        old = os.umask(0o077)
        open(envf + ".tmp", "w").write("\n".join(lines) + "\n")
        os.umask(old)
        os.replace(envf + ".tmp", envf)
    st, data = req("GET", "/api/play", extra={"X-Requested-With": "wenilla", "Accept": "application/json"})
    if st != 200:
        print(f"ERR /api/play answered {st}"); raise SystemExit
    print("REALM " + str(json.loads(data).get("realm", "")))
except SystemExit:
    pass
except Exception as e:
    print(f"ERR {type(e).__name__}")
PY
)
  case "$PLAY" in
    "REALM $REALMD_NAME") ok "/api/play names the realm realmd shows (\"$REALMD_NAME\"): no realm list" ;;
    REALM*) bad "/api/play names \"${PLAY#REALM }\", realmd \"$REALMD_NAME\": players see the realm list" "bash hetzner/bossfights_up.sh site" ;;
    *) skip "/api/play realm name" "${PLAY#ERR }" ;;
  esac
fi
BFD=$(grep -o '^[a-z0-9.-]* {' "$BCP/Caddyfile.site" 2>/dev/null | head -1 | cut -d' ' -f1)
if [ -n "$BFD" ] && getent hosts "$BFD" >/dev/null 2>&1; then
  LOC=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 15 "https://$BFD/")
  case "$LOC" in 302*mode=boss*) ok "https://$BFD/ opens in Boss Fights" ;; *) bad "https://$BFD/ doesn't redirect to ?mode=boss" "$LOC" ;; esac
else
  skip "the Boss Fights address" "no DNS for it yet"
fi

echo "== 4/6 Herald Lite"
if [ -d "$SRC" ]; then
  SUM=$(cd "$SRC" && find Cargo.toml Cargo.lock src -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
  if [ ! -x "$BIN" ] || [ "$(cat "$BCP/bin/.src" 2>/dev/null)" != "$SUM" ]; then
    mkdir -p "$BCP/bin" "$BCP/cargo"
    docker run --rm -v "$SRC":/src:ro -v "$BCP/cargo":/usr/local/cargo/registry -v "$BCP/bin":/out \
      -e CARGO_TARGET_DIR=/tmp/t rust:1-bookworm sh -c 'cd /src && cargo build --release -q && cp /tmp/t/release/heraldlite /out/' \
      && echo "$SUM" > "$BCP/bin/.src"
  fi
fi
[ -x "$BIN" ] && ok "Herald Lite built" || { bad "Herald Lite could not be built ($SRC)"; finish; }
[ -f "$SCN" ] || { bad "no scenario $SCN"; finish; }

echo "== 5/6 the self-test scenario (about 4 minutes)"
# Herald Lite runs in a container on the stack's own network: realmd and the world server by their names there.
# The passwords reach it through the environment only (docker -e NAME, values from this shell).
export HL_PASS="$BF_PASS1" HL_USER2="$BF_USER2" HL_PASS2="$BF_PASS2" HL_CHAR2="$BF_CHAR2"
export HL_CREATE_A=${BF_CREATE_A:-1:1} HL_CREATE_B=${BF_CREATE_B:-8:5}   # a Human Warrior (tank), a Troll Priest (healer)
# bot fill (0054): its own scenario after the main one, only where the server has it on
BOTFILL=$(conf OpenVanilla.BossFights.BotFill)
BOTS_ARGS=()
if [ "$BOTFILL" = 1 ] && [ -f "$SCN_BOTS" ]; then
  BOTS_ARGS=(-v "$SCN_BOTS":/s/bossfights_botfill.txt:ro)
  BOTS_S=(-s /s/bossfights_botfill.txt)
  echo "   and bot fill (bossfights_botfill.txt, about 2 more minutes)"
else
  BOTS_S=()
  skip "bot fill" "off on this server (bash hetzner/bossfights_up.sh botfill on)"
fi
docker run --rm --network "$NET" -v "$BIN":/usr/local/bin/heraldlite:ro -v "$SCN":/s/bossfights_selftest.txt:ro "${BOTS_ARGS[@]}" \
  -e HL_PASS -e HL_USER2 -e HL_PASS2 -e HL_CHAR2 -e HL_CREATE_A -e HL_CREATE_B \
  debian:bookworm-slim heraldlite --host owduels-realmd:3724 --world owduels-mangosd:8085 --user "$BF_USER1" \
  --char "$BF_CHAR1" --timeout 15 -s /s/bossfights_selftest.txt "${BOTS_S[@]}" > "$OUT.tmp" 2> "$BCP/selftest-last.log"
HL_RC=$?
mv "$OUT.tmp" "$OUT"; chmod 600 "$OUT" "$BCP/selftest-last.log"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT" 2>/dev/null || { bad "Herald Lite gave no report (exit $HL_RC; $BCP/selftest-last.log)"; }
[ "$HL_RC" -eq 0 ] && ok "every scenario step passed" || bad "the scenario failed (exit $HL_RC)"

echo "== 6/6 the database and the website"
# the scenario's two runs: a tier-1 clear with one wipe, a tier-2 run nobody finished; both marked test
R=$(sqle classiccharacters "SELECT COALESCE(SUM(cleared = 1 AND wipes = 1 AND tier = 1), 0), COALESCE(SUM(cleared = 0 AND tier = 2), 0), COUNT(*)
      FROM bossfights_result WHERE test = 1 AND ended >= $T0 AND (members LIKE '$BF_CHAR1:%' OR members LIKE '%,$BF_CHAR1:%')")
read -r CL NC ALL <<< "$R"
[ "${CL:-0}" -ge 1 ] && ok "the clear is stored (test row, tier 1, one wipe)" || bad "no stored test clear" "rows: ${ALL:-0}"
[ "${NC:-0}" -ge 1 ] && ok "the abandoned tier-2 run is stored, not cleared" || bad "no stored tier-2 run"
N=$(sqle classiccharacters "SELECT COUNT(*) FROM bossfights_result WHERE test = 0 AND ended >= $T0 AND (members LIKE '%$BF_CHAR1:%' OR members LIKE '%$BF_CHAR2:%')")
[ "${N:-0}" = 0 ] && ok "no run of the test characters counted as a player's" || bad "test runs stored as players' runs" "$N"
N=$(sqle classiccharacters "SELECT COUNT(*) FROM bossfights_now WHERE started >= $T0 AND size = 2")
[ "${N:-0}" = 0 ] && ok "no test run in \"raids now\"" || bad "a test run is in bossfights_now" "$N"
if [ "${#BOTS_S[@]}" -gt 0 ]; then
  # the bot-filled run: the tester and four bots, cleared, marked test (its bots rank it apart anyway)
  N=$(sqle classiccharacters "SELECT COUNT(*) FROM bossfights_result WHERE test = 1 AND ended >= $T0 AND bots = 4 AND size = 5 AND cleared = 1
        AND members LIKE '$BF_CHAR1:%'")
  if [ "${N:-0}" -ge 1 ]; then ok "the bot-filled run is stored (the tester and 4 bots, cleared, test row)"
  elif grep -q '"bf_pop"' "$OUT" 2>/dev/null; then bad "the bot-filled run popped but no row with 4 bots was stored"
  else skip "the bot-filled run's row" "the raid was not filled on this server (see the scenario's skipped steps)"; fi
  # every fill bot logged out again (a few seconds after the run)
  N=1
  for _ in 1 2 3 4 5 6; do
    N=$(sqle classiccharacters "SELECT COUNT(*) FROM bossfights_fill_bot b JOIN characters c ON c.guid = b.guid WHERE c.online = 1")
    [ "${N:-0}" = 0 ] && break; sleep 5
  done
  [ "${N:-0}" = 0 ] && ok "no fill bot left online" || bad "fill bots still online after the run" "$N"
fi
bash "$LIVE_CP/repo/hetzner/bossfights_up.sh" live >/dev/null 2>&1 || bash "$HERE/hetzner/bossfights_up.sh" live >/dev/null 2>&1 || true
if [ -s "$PUB/bossfights_live.json" ]; then
  if grep -qi -e "\"$BF_CHAR1\"" -e "\"$BF_CHAR2\"" "$PUB/bossfights_live.json"; then bad "the test characters are on the website (bossfights_live.json)"
  else ok "nothing of the self-test on the website (bossfights_live.json)"; fi
else
  skip "bossfights_live.json" "not written yet"
fi
finish
