#!/usr/bin/env bash
# Runs inside the pg-upgrade Job pod, from the official postgres or postgis/postgis image.
# MODE=upgrade:  copy SOURCE into the empty TARGET in one transaction, verify, commit; SOURCE stays read-only.
# MODE=rehearse: copy SOURCE into a throwaway server in this pod and verify; nothing else changes.
# MODE=rollback: make SOURCE writable again.
# Never prints passwords; they reach psql/pg_dump only through PGPASSWORD.
set -euo pipefail

WORK="${WORK:-/work}"
PORT="${PORT:-5432}"
READY_SECONDS="${READY_SECONDS:-300}"

fail() {
  echo "::error::$1"
  if [ -n "${2:-}" ]; then echo "Fix: $2"; fi
  exit 1
}

for v in MODE SOURCE_HOST SRC_DB SRC_USER SRC_PASSWORD; do
  [ -n "${!v:-}" ] || fail "${v} is not set in the upgrade Job." "Check that the secret holds database-name, database-user and database-password."
done
case "$MODE" in
  upgrade)
    for v in TARGET_HOST TGT_DB TGT_USER TGT_PASSWORD; do
      [ -n "${!v:-}" ] || fail "${v} is not set in the upgrade Job." "Check that the target secret holds database-name, database-user and database-password."
    done
    ;;
  rehearse | rollback) ;;
  *) fail "Unknown MODE '${MODE}'." "Use upgrade, rehearse or rollback." ;;
esac

src_psql() { PGPASSWORD="$SRC_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h "$SOURCE_HOST" -p "$PORT" -U "$SRC_USER" -d "$SRC_DB" "$@"; }
# Our own sessions on the source stay writable after the write pause
src_admin() { PGOPTIONS='-c default_transaction_read_only=off' src_psql "$@"; }
tgt_psql() { PGPASSWORD="$TGT_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h "$TARGET_HOST" -p "$PORT" -U "$TGT_USER" -d "$TGT_DB" "$@"; }

wait_ready() { # host user label
  local deadline=$((SECONDS + READY_SECONDS))
  # -U: OpenShift's random UID has no passwd entry for libpq to take a default user from
  until pg_isready -q -h "$1" -p "$PORT" -U "$2" -t 10; do
    [ "$SECONDS" -lt "$deadline" ] || fail "The ${3} database (${1}) did not accept connections within ${READY_SECONDS}s." "Make sure its pod is running and Ready, then re-run."
    sleep 5
  done
}

major_of() { # psql function -> server major
  local n
  n="$("$1" -At -c 'SHOW server_version_num')"
  echo $((n / 10000))
}

# User relations, functions and schemas that no extension owns. pg_catalog is searched implicitly.
USER_NS="n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp\_%'"
NOT_EXT_CLASS="NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d WHERE d.classid = 'pg_catalog.pg_class'::pg_catalog.regclass AND d.objid = c.oid AND d.deptype = 'e')"
# Rows inserted, updated or deleted in user tables, from the statistics views
WRITES_SQL="SELECT coalesce(pg_catalog.sum(n_tup_ins + n_tup_upd + n_tup_del), 0) FROM pg_catalog.pg_stat_user_tables"
TABLES_SQL="SELECT pg_catalog.format('%I.%I', n.nspname, c.relname) AS t FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND ${USER_NS} AND ${NOT_EXT_CLASS}"
SEQS_SQL="SELECT pg_catalog.format('%I.%I', s.schemaname, s.sequencename) AS q, s.last_value FROM pg_catalog.pg_sequences s JOIN pg_catalog.pg_namespace n ON n.nspname = s.schemaname JOIN pg_catalog.pg_class c ON c.relnamespace = n.oid AND c.relname = s.sequencename WHERE ${USER_NS} AND ${NOT_EXT_CLASS}"

unfreeze_source() {
  src_admin -v db="$SRC_DB" <<'SQL'
ALTER DATABASE :"db" RESET default_transaction_read_only;
SQL
}

echo "Mode: ${MODE}"
wait_ready "$SOURCE_HOST" "$SRC_USER" source
SRC_MAJOR="$(major_of src_psql)"
CLIENT_MAJOR="$(pg_dump --version | sed -E 's/^[^0-9]*([0-9]+).*/\1/')"
echo "Source ${SOURCE_HOST}: PostgreSQL ${SRC_MAJOR}"

if [ "$MODE" = rollback ]; then
  unfreeze_source || fail "Could not make ${SOURCE_HOST} writable again." "Connect as the database owner or a superuser and run: ALTER DATABASE <name> RESET default_transaction_read_only"
  echo "Source ${SOURCE_HOST} accepts writes again (new sessions; restart clients that are still connected)"
  exit 0
fi

[ "$SRC_MAJOR" -ge 10 ] || fail "Source is PostgreSQL ${SRC_MAJOR}; this action supports 10 and newer." "Upgrade to 10+ with bcgov/devops-scripts oc/db_transfer.sh first."
[ "$CLIENT_MAJOR" -gt "$SRC_MAJOR" ] || fail "Image is PostgreSQL ${CLIENT_MAJOR}, not newer than the source (${SRC_MAJOR}), so there is nothing to upgrade." "Set image to the new major, e.g. postgres:17."

if [ "$MODE" = upgrade ]; then
  wait_ready "$TARGET_HOST" "$TGT_USER" target
  TGT_MAJOR="$(major_of tgt_psql)"
  echo "Target ${TARGET_HOST}: PostgreSQL ${TGT_MAJOR}"
  [ "$TGT_MAJOR" -eq "$CLIENT_MAJOR" ] || fail "Target runs PostgreSQL ${TGT_MAJOR} but the image is ${CLIENT_MAJOR}." "Use the target's image (same repository and major) for image."

  # The target must be empty: no relations or functions outside extensions. Empty schemas are
  # allowed (e.g. tiger_data from the postgis/postgis image) and reused by the restore.
  FOUND="$(tgt_psql -At <<SQL
SELECT (SELECT pg_catalog.count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f') AND ${USER_NS} AND ${NOT_EXT_CLASS})
     + (SELECT pg_catalog.count(*) FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
         WHERE ${USER_NS} AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d WHERE d.classid = 'pg_catalog.pg_proc'::pg_catalog.regclass AND d.objid = p.oid AND d.deptype = 'e'))
SQL
)"
  [ "$FOUND" -eq 0 ] || fail "Target ${TARGET_HOST} is not empty (${FOUND} relation(s) or function(s) found), so it was not overwritten." "Point target at a new, empty database. If this is a failed earlier attempt, delete the target StatefulSet and its PVC and redeploy it."
fi

# Every source extension must be installable where the copy lands
EXT_SQL="SELECT e.extname FROM pg_catalog.pg_extension e WHERE e.extname <> 'plpgsql' ORDER BY 1"
EXTS="$(src_psql -At -c "$EXT_SQL")"
[ -z "$EXTS" ] || echo "Source extensions: $(echo "$EXTS" | paste -sd' ')"

mkdir -p "$WORK"
EXPECTED="${WORK}/expected.sql"
VERIFY="${WORK}/verify.sql"

if [ "$MODE" = rehearse ]; then
  # Throwaway server from this image, socket only, on the pod's emptyDir
  (
    export PGDATA="${WORK}/pgdata" POSTGRES_USER=rehearsal POSTGRES_DB=rehearsal
    POSTGRES_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    export POSTGRES_PASSWORD
    # Official image helpers: initdb (nss_wrapper for OpenShift's random UID), pg_hba, temp server
    # shellcheck disable=SC1091
    source /usr/local/bin/docker-entrypoint.sh
    docker_setup_env
    docker_create_db_directories
    docker_init_database_dir > /dev/null
    pg_setup_hba_conf postgres
    docker_temp_server_start postgres > /dev/null
    docker_setup_db
  ) || fail "Could not start the throwaway PostgreSQL ${CLIENT_MAJOR} server for the rehearsal." "Check the image and the Job's memory_limit."
  REHEARSAL_UP=1
  dest_psql() { psql -X -q -v ON_ERROR_STOP=1 -h /var/run/postgresql -U rehearsal -d rehearsal "$@"; }
  avail() { dest_psql -At "$@"; }
  STRICT_SEQ=false
else
  dest_psql() { tgt_psql "$@"; }
  avail() { tgt_psql -At "$@"; }
  STRICT_SEQ=true
fi

stop_rehearsal() {
  if [ "${REHEARSAL_UP:-0}" = 1 ]; then pg_ctl -D "${WORK}/pgdata" -m fast -w stop > /dev/null 2>&1 || true; fi
}

if [ -n "$EXTS" ]; then
  MISSING="$(while read -r e; do
    [ "$(avail -c "SELECT pg_catalog.count(*) FROM pg_catalog.pg_available_extensions WHERE name = '${e//\'/\'\'}'")" = 1 ] || echo "$e"
  done <<< "$EXTS")"
  if [ -n "$MISSING" ]; then
    stop_rehearsal
    fail "Extension(s) $(echo "$MISSING" | paste -sd' ') used by the source are not available in PostgreSQL ${CLIENT_MAJOR} from this image." "Use an image that provides them, e.g. postgis/postgis:${CLIENT_MAJOR}-<postgis version> for PostGIS."
  fi
fi

FROZEN=0
on_exit() {
  rc=$?
  if [ -n "${SNAP_PID:-}" ]; then kill "${SNAP_PID}" 2> /dev/null || true; fi
  if [ -n "${PSQL_PID:-}" ]; then kill "${PSQL_PID}" 2> /dev/null || true; fi
  stop_rehearsal
  if [ "$rc" -ne 0 ] && [ "$FROZEN" = 1 ]; then
    if unfreeze_source; then
      echo "Source ${SOURCE_HOST} accepts writes again; nothing was committed to the target."
    else
      echo "::error::Could not lift the write pause on ${SOURCE_HOST}."
      echo "Fix: re-run this action with mode: rollback to make the source writable again."
    fi
  fi
}
trap on_exit EXIT

if [ "$MODE" = upgrade ]; then
  # Write pause: new sessions on the source database start read-only, then existing sessions are ended.
  # Clients reconnect read-only; reads keep working, writes fail until the app moves to the target.
  src_admin -v db="$SRC_DB" <<'SQL' || fail "Could not pause writes on ${SOURCE_HOST}." "The source database user must own the database or be a superuser."
ALTER DATABASE :"db" SET default_transaction_read_only = on;
SQL
  FROZEN=1
  # Sessions that start from here on get the read-only default; every older one must go
  PAUSED_AT="$(src_admin -At -c 'SELECT pg_catalog.now()')"
  echo "Writes paused on ${SOURCE_HOST} (default_transaction_read_only=on)"
  src_admin -At -o /dev/null -c "SELECT pg_catalog.pg_terminate_backend(pid) FROM pg_catalog.pg_stat_activity
    WHERE datname = pg_catalog.current_database() AND pid <> pg_catalog.pg_backend_pid() AND backend_type = 'client backend'
      AND pg_catalog.pg_has_role(usesysid, 'MEMBER')"
  LEFT=""
  for _ in $(seq 1 15); do
    LEFT="$(src_admin -At -v since="$PAUSED_AT" <<'SQL'
SELECT pg_catalog.string_agg(DISTINCT usename::text, ' ') FROM pg_catalog.pg_stat_activity
WHERE datname = pg_catalog.current_database() AND pid <> pg_catalog.pg_backend_pid()
  AND backend_type = 'client backend' AND backend_start < :'since'::timestamptz;
SQL
)"
    [ -n "$LEFT" ] || break
    sleep 2
  done
  [ -z "$LEFT" ] || fail "Sessions opened before the write pause are still connected (roles: ${LEFT}) and could still write." "Stop those clients, or use a source user that can end their sessions, then re-run."
  # Committed rows reach the statistics views within about 10s (a backend reports when it
  # goes idle); wait that out before taking the baseline the final write check compares with
  [ "$(src_admin -At -c 'SHOW track_counts')" = on ] || fail "track_counts is off on ${SOURCE_HOST}, so writes during the copy can't be detected." "Turn track_counts on (the PostgreSQL default) and re-run."
  sleep "${STATS_SETTLE_SECONDS:-11}"
  WRITES_BASE="$(src_admin -At -c "$WRITES_SQL")"
fi

# One snapshot for the dump and the expected counts, so they describe the same data
coproc SNAP { src_psql -At; }
echo "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; SELECT pg_catalog.pg_export_snapshot();" >&"${SNAP[1]}"
SNAPSHOT=""
read -r -t 60 SNAPSHOT <&"${SNAP[0]}" || true
[[ "$SNAPSHOT" =~ ^[0-9A-F]+-[0-9A-F]+(-[0-9]+)?$ ]] || fail "Could not take a snapshot of ${SOURCE_HOST}." "Check the source database logs; nothing was copied."

# Prints why the source may have changed since the write pause, or nothing. The pause is a
# default that a client can override, so this check is what proves no row was missed.
source_writes() {
  local now open
  sleep "${STATS_SETTLE_SECONDS:-11}"
  now="$(src_admin -At -c "$WRITES_SQL")" || return 1
  open="$(src_admin -At -c "SELECT pg_catalog.count(*) FROM pg_catalog.pg_stat_activity
    WHERE datname = pg_catalog.current_database() AND backend_type = 'client backend'
      AND backend_xid IS NOT NULL AND pid <> pg_catalog.pg_backend_pid()")" || return 1
  if [ "$now" != "$WRITES_BASE" ]; then echo "$((now - WRITES_BASE)) row(s) inserted, updated or deleted"; fi
  if [ "$open" != 0 ]; then echo "${open} write transaction(s) still open"; fi
}

{
  echo "CREATE TEMP TABLE pgup_rows (tbl text PRIMARY KEY, n bigint NOT NULL);"
  echo "CREATE TEMP TABLE pgup_seqs (seq text PRIMARY KEY, v bigint);"
  src_psql -At -v snap="$SNAPSHOT" <<SQL
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET TRANSACTION SNAPSHOT :'snap';
SELECT pg_catalog.format('SELECT pg_catalog.format(%L, %L, pg_catalog.count(*)) FROM %s',
  'INSERT INTO pg_temp.pgup_rows VALUES (%L, %s);', t, t) FROM (${TABLES_SQL}) s ORDER BY 1 \gexec
SELECT pg_catalog.format('INSERT INTO pg_temp.pgup_seqs VALUES (%L, %L);', q, last_value) FROM (${SEQS_SQL}) s ORDER BY 1;
COMMIT;
SQL
} > "$EXPECTED" || fail "Could not count the source rows." "Check the source database logs; nothing was copied."
echo "Source: $(grep -c '^INSERT INTO pg_temp.pgup_rows' "$EXPECTED" || true) table(s), $(grep -c '^INSERT INTO pg_temp.pgup_seqs' "$EXPECTED" || true) sequence(s)"

{
  # pg_restore output raises client_min_messages to warning; show the per-table counts
  echo "SET client_min_messages = notice;"
  cat "$EXPECTED"
  cat <<SQL
DO \$pgup\$
DECLARE
  r record;
  got bigint;
  bad int := 0;
  strict_seq boolean := ${STRICT_SEQ};
BEGIN
  FOR r IN SELECT tbl, n FROM pg_temp.pgup_rows ORDER BY tbl LOOP
    IF pg_catalog.to_regclass(r.tbl) IS NULL THEN
      RAISE WARNING 'table % is missing from the copy', r.tbl;
      bad := bad + 1;
      CONTINUE;
    END IF;
    EXECUTE 'SELECT pg_catalog.count(*) FROM ' || r.tbl INTO got;
    IF got <> r.n THEN
      RAISE WARNING 'row count mismatch for %: source %, copy %', r.tbl, r.n, got;
      bad := bad + 1;
    ELSE
      RAISE NOTICE '%: % rows', r.tbl, got;
    END IF;
  END LOOP;
  FOR r IN SELECT s.t FROM (${TABLES_SQL}) s WHERE s.t NOT IN (SELECT tbl FROM pg_temp.pgup_rows) LOOP
    RAISE WARNING 'table % is in the copy but not in the source', r.t;
    bad := bad + 1;
  END LOOP;
  FOR r IN SELECT e.seq, e.v, s.last_value AS got FROM pg_temp.pgup_seqs e LEFT JOIN (${SEQS_SQL}) s ON s.q = e.seq LOOP
    IF (strict_seq AND r.got IS DISTINCT FROM r.v) OR (NOT strict_seq AND r.v IS NOT NULL AND (r.got IS NULL OR r.got < r.v)) THEN
      RAISE WARNING 'sequence % differs: source %, copy %', r.seq, r.v, r.got;
      bad := bad + 1;
    END IF;
  END LOOP;
  IF bad > 0 THEN
    RAISE EXCEPTION 'verification found % difference(s); the copy was rolled back', bad;
  END IF;
  RAISE NOTICE 'verified % table(s) and % sequence(s)', (SELECT pg_catalog.count(*) FROM pg_temp.pgup_rows), (SELECT pg_catalog.count(*) FROM pg_temp.pgup_seqs);
END
\$pgup\$;
SQL
} > "$VERIFY"

echo "Dumping ${SRC_DB} from PostgreSQL ${SRC_MAJOR}"
DUMP="${WORK}/source.dump"
PGPASSWORD="$SRC_PASSWORD" pg_dump -h "$SOURCE_HOST" -p "$PORT" -U "$SRC_USER" -d "$SRC_DB" \
  --snapshot="$SNAPSHOT" --format=custom --file="$DUMP" \
  || fail "pg_dump of ${SOURCE_HOST} failed; nothing was copied." "Read the error above; the Job's /work volume must hold the compressed dump."
echo "Dump: $(du -h "$DUMP" | cut -f1)"

# Schemas that already exist where the copy lands (public, or ones an image's init scripts
# made, like PostGIS topology/tiger) are reused instead of created again
LIST="${WORK}/restore.list"
dest_psql -At -c "SELECT nspname FROM pg_catalog.pg_namespace" > "${WORK}/schemas"
pg_restore --list "$DUMP" | awk 'NR == FNR { have[$0] = 1; next }
  $4 == "SCHEMA" && $5 == "-" && ($6 in have) { print ";" $0; next } { print }' "${WORK}/schemas" - > "$LIST"

echo "Restoring into PostgreSQL ${CLIENT_MAJOR} and verifying in one transaction"
# psql reads from a FIFO so COMMIT is sent only after the restore and checks have run and the
# source is re-checked for writes. Any error or failed check ends the session without COMMIT,
# so the server rolls everything back.
FIFO="${WORK}/restore.fifo"
SYNC="${WORK}/restore.sync"
PSQL_LOG="${WORK}/restore.log"
rm -f "$FIFO" "$SYNC"
mkfifo "$FIFO"
dest_psql -o /dev/null < "$FIFO" > "$PSQL_LOG" 2>&1 &
PSQL_PID=$!
exec 3> "$FIFO"
restore_ok() {
  # Subshell with its own exit codes: errexit doesn't apply inside a condition
  (
    echo 'BEGIN;'
    pg_restore --use-list="$LIST" --no-owner --no-privileges --file=- "$DUMP" || exit 1
    cat "$VERIFY" || exit 1
    # Tell this script when psql has run everything above (restricted mode ends with the dump)
    printf '%s\n' "\\o ${SYNC}" "\\qecho synced" "\\o /dev/null"
  ) >&3 || return 1
  until grep -qx synced "$SYNC" 2> /dev/null; do
    kill -0 "$PSQL_PID" 2> /dev/null || return 1
    sleep 1
  done
  if [ "$MODE" = upgrade ]; then
    local writes
    writes="$(source_writes)" || { echo "::error::Could not check the source for writes during the copy."; return 1; }
    if [ -n "$writes" ]; then
      echo "::error::The source changed during the copy: $(echo "$writes" | paste -sd';' | sed 's/;/; /g')."
      echo "Fix: stop clients that turn off default_transaction_read_only or write as another role, then re-run."
      return 1
    fi
    echo "No writes on the source during the copy"
  fi
  echo 'COMMIT;' >&3
}
RESTORED=0
if restore_ok; then RESTORED=1; fi
exec 3>&-
PSQL_RC=0
wait "$PSQL_PID" || PSQL_RC=$?
sed -E 's/^psql:[^ ]+ //' "$PSQL_LOG"
if [ "$RESTORED" != 1 ] || [ "$PSQL_RC" -ne 0 ]; then
  if [ "$MODE" = upgrade ]; then
    fail "Copy or verification failed; nothing was committed to ${TARGET_HOST}." "Read the messages above. The source is writable again; fix the cause and re-run."
  fi
  fail "Rehearsal failed: the copy of ${SOURCE_HOST} into PostgreSQL ${CLIENT_MAJOR} did not restore or verify." "Read the messages above and fix the cause before the real upgrade runs."
fi

if [ "$MODE" = upgrade ]; then
  # pg_restore doesn't gather planner statistics; without them the first queries plan badly
  PGOPTIONS='-c client_min_messages=error' tgt_psql -c 'ANALYZE' || echo "::warning::ANALYZE on ${TARGET_HOST} failed; run it before heavy use."
  echo "Upgrade complete: ${TARGET_HOST} holds a verified copy. ${SOURCE_HOST} stays read-only as the rollback copy."
else
  echo "Rehearsal passed: ${SOURCE_HOST} restores into PostgreSQL ${CLIENT_MAJOR} with matching row counts. Nothing was changed."
fi
