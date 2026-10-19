#!/usr/bin/env bash
# Moves the database tables made under the project's old name (prefix OLD below) to the Open Vanilla
# names, in the MariaDB of one realm stack:  bash openvanilla_rename_tables.sh /opt/wenilla-realm
# Safe to re-run: a table whose new name is already taken is left alone. The world server and the realm
# service are stopped while it runs; set KEEP_STOPPED=1 when the caller starts them again itself.
set -euo pipefail
DIR=${1:-/opt/wenilla-realm}
OLD=openwow   # the project's name before Open Vanilla
cd "$DIR"
set -a; . ./.env; set +a
sql() { MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot -N "$@"; }
SUFFIX="SUBSTRING(t.table_name, CHAR_LENGTH('$OLD') + 1)"
Q="SELECT CONCAT('RENAME TABLE \`', t.table_schema, '\`.\`', t.table_name, '\` TO \`', t.table_schema, '\`.\`openvanilla', $SUFFIX, '\`;')
   FROM information_schema.tables t
   WHERE t.table_name LIKE '${OLD}\\_%'
     AND NOT EXISTS (SELECT 1 FROM information_schema.tables u
                     WHERE u.table_schema = t.table_schema AND u.table_name = CONCAT('openvanilla', $SUFFIX))"
STMTS=$(sql -e "$Q")
if [ -z "$STMTS" ]; then echo "Table names: already Open Vanilla"; exit 0; fi
RUNNING=$(docker compose ps --status running --services 2>/dev/null | grep -x -E 'mangosd|realm' || true)
[ -z "$RUNNING" ] || docker compose stop $RUNNING
printf '%s\n' "$STMTS" | sql
echo "Table names: $(printf '%s\n' "$STMTS" | grep -c .) table(s) moved to the Open Vanilla names"
if [ -n "$RUNNING" ] && [ "${KEEP_STOPPED:-0}" != 1 ]; then docker compose start $RUNNING; fi
