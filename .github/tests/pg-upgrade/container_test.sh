#!/usr/bin/env bash
# Functions run through check() and trap, which shellcheck cannot follow
# shellcheck disable=SC2329
# Runs pg-upgrade/scripts/job.sh against real PostgreSQL/PostGIS containers, no cluster.
# ENGINE=docker (CI) or podman. The job container runs as an arbitrary non-root UID, like OpenShift.
set -euo pipefail

ENGINE="${ENGINE:-docker}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOB="${HERE}/../../../pg-upgrade/scripts/job.sh"
NET="pgup-test-$$"
PW="test-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
FAILED=0
LOG="$(mktemp)"

cleanup() {
  local ids
  ids="$("$ENGINE" ps -aq --filter "label=pgup-test=${NET}")"
  # shellcheck disable=SC2086 # one container id per word
  [ -z "$ids" ] || "$ENGINE" rm -f -v $ids > /dev/null 2>&1 || true
  "$ENGINE" network rm "$NET" > /dev/null 2>&1 || true
  rm -f "$LOG"
}
trap cleanup EXIT
"$ENGINE" network create "$NET" > /dev/null

db() { # name image
  "$ENGINE" run -d --name "$1" --label "pgup-test=${NET}" --network "$NET" \
    -e POSTGRES_USER=app -e POSTGRES_PASSWORD="$PW" -e POSTGRES_DB=app "$2" > /dev/null
}
sql() { # container sql [db]
  "$ENGINE" exec -i "$1" psql -X -q -At -v ON_ERROR_STOP=1 -U app -d "${3:-app}" -c "$2"
}
wait_db() {
  for _ in $(seq 1 60); do
    if "$ENGINE" exec "$1" pg_isready -q -U app -d app -h 127.0.0.1 2> /dev/null; then sleep 1; return 0; fi
    sleep 1
  done
  echo "database $1 did not start"
  exit 1
}
# podman adds the UID to /etc/passwd; docker and OpenShift don't
NO_PASSWD=()
[ "$ENGINE" != podman ] || NO_PASSWD=(--passwd=false)
run_job() { # image mode source [target] [extra env...]
  local image="$1" mode="$2" src="$3" tgt="${4:-}"
  shift 4 || shift $#
  "$ENGINE" run --rm "${NO_PASSWD[@]}" --label "pgup-test=${NET}" --network "$NET" --user "${JOB_UID:-1000680000}:0" \
    --tmpfs /work:rw,mode=1777 --tmpfs /var/run/postgresql:rw,mode=1777 \
    -e MODE="$mode" -e SOURCE_HOST="$src" -e SRC_DB=app -e SRC_USER=app -e SRC_PASSWORD="$PW" \
    -e TARGET_HOST="$tgt" -e TGT_DB="${TGT_DB:-app}" -e TGT_USER="${TGT_USER:-app}" -e TGT_PASSWORD="$PW" \
    -e READY_SECONDS=60 "$@" \
    -v "${JOB}:/job.sh:ro" --entrypoint bash "$image" /job.sh
}
check() { # name expected-status grep-pattern -- command...
  local name="$1" want="$2" pattern="$3"
  shift 4
  local rc=0
  "$@" > "$LOG" 2>&1 || rc=$?
  if { [ "$want" = pass ] && [ "$rc" -ne 0 ]; } || { [ "$want" = fail ] && [ "$rc" -eq 0 ]; } || ! grep -qE -- "$pattern" "$LOG"; then
    echo "FAIL: ${name} (exit ${rc}, wanted ${want}, pattern '${pattern}')"
    sed 's/^/    /' "$LOG"
    FAILED=1
  else
    echo "PASS: ${name}"
  fi
  if grep -qF -- "$PW" "$LOG"; then
    echo "FAIL: ${name} printed the database password"
    FAILED=1
  fi
}
equals() { # name actual expected
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (got '$2', want '$3')"; FAILED=1; fi
}

PG_OLD="${PG_OLD:-postgres:13}"
PG_NEW="${PG_NEW:-postgres:17}"
GIS_OLD="${GIS_OLD:-postgis/postgis:13-3.5}"
GIS_NEW="${GIS_NEW:-postgis/postgis:17-3.5}"

db src "$PG_OLD"
db tgt "$PG_NEW"
db gsrc "$GIS_OLD"
db gtgt "$GIS_NEW"
for c in src tgt gsrc gtgt; do wait_db "$c"; done

sql src "CREATE SCHEMA sales;
  CREATE TABLE public.users (id serial PRIMARY KEY, name text NOT NULL);
  CREATE TABLE sales.\"Orders\" (id bigserial PRIMARY KEY, user_id int REFERENCES public.users(id), note text);
  CREATE TABLE public.audit (id bigserial PRIMARY KEY, at timestamptz DEFAULT now());
  CREATE TABLE public.flyway_schema_history (installed_rank int PRIMARY KEY, version text);
  CREATE VIEW public.user_orders AS SELECT u.name, o.id FROM public.users u JOIN sales.\"Orders\" o ON o.user_id = u.id;
  INSERT INTO public.users (name) SELECT 'user ' || g FROM generate_series(1, 500) g;
  INSERT INTO sales.\"Orders\" (user_id, note) SELECT 1 + g % 500, repeat('x', g % 50) FROM generate_series(1, 2000) g;
  INSERT INTO public.flyway_schema_history VALUES (1, '1'), (2, '2');"
sql gsrc "CREATE TABLE public.places (id serial PRIMARY KEY, geom geometry(Point, 4326));
  INSERT INTO public.places (geom) SELECT ST_SetSRID(ST_MakePoint(-123 + g / 1000.0, 49), 4326) FROM generate_series(1, 300) g;"

check "rehearse: copies and verifies without changes" pass "Rehearsal passed" -- run_job "$PG_NEW" rehearse src
equals "rehearse: target untouched" "$(sql tgt "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')")" 0
equals "rehearse: source still writable" "$(sql src "INSERT INTO public.users (name) VALUES ('after rehearsal') RETURNING 'ok'")" ok

check "same major fails" fail "Fix: Set image to the new major" -- run_job "$PG_OLD" rehearse src
check "missing PostGIS in a plain image fails" fail "Extension\\(s\\) postgis.*not available" -- run_job "$PG_NEW" rehearse gsrc
check "image major must match the target" fail "Target runs PostgreSQL 17 but the image is 16" -- run_job "${PG_MID:-postgres:16}" upgrade src tgt

# A client that overrides the write pause and keeps writing must fail the upgrade, not lose rows
"$ENGINE" exec -d src bash -c 'while [ ! -f /tmp/stop-writer ]; do
  PGOPTIONS="-c default_transaction_read_only=off" psql -X -q -U app -d app -c "INSERT INTO public.audit DEFAULT VALUES" > /dev/null 2>&1
  sleep 0.2
done' > /dev/null
sleep 1
# Either check may catch it first: the write check, or a sequence that moved after the snapshot
check "writes during the copy fail the upgrade" fail "The source changed during the copy|sequence public.audit_id_seq differs" -- run_job "$PG_NEW" upgrade src tgt
"$ENGINE" exec src touch /tmp/stop-writer
sleep 1
equals "writes during the copy: target still empty" "$(sql tgt "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')")" 0
equals "writes during the copy: source writable again" "$(sql src "INSERT INTO public.audit DEFAULT VALUES RETURNING 'ok'")" ok

check "upgrade: copies and verifies" pass "Upgrade complete" -- run_job "$PG_NEW" upgrade src tgt
if grep -q 'sales."Orders": 2000 rows' "$LOG"; then echo "PASS: upgrade: per-table counts printed"; else echo "FAIL: per-table counts missing"; sed "s/^/    /" "$LOG"; FAILED=1; fi
equals "upgrade: users copied" "$(sql tgt "SELECT count(*) FROM public.users")" 501
equals "upgrade: view copied" "$(sql tgt "SELECT count(*) FROM public.user_orders")" 2000
equals "upgrade: sequence continues" "$(sql tgt "SELECT nextval('public.users_id_seq')")" 502
if sql src "INSERT INTO public.users (name) VALUES ('lost?')" > /dev/null 2>&1; then
  echo "FAIL: upgrade: source still accepts writes"; FAILED=1
else
  echo "PASS: upgrade: source is read-only"
fi
equals "upgrade: source reads still work" "$(sql src "SELECT count(*) FROM public.users")" 501

check "non-empty target is refused" fail "is not empty" -- run_job "$PG_NEW" upgrade src tgt
check "rollback makes the source writable" pass "accepts writes again" -- run_job "$PG_NEW" rollback src
equals "rollback: source writable" "$(sql src "INSERT INTO public.users (name) VALUES ('after rollback') RETURNING 'ok'")" ok

# A failure part-way through the restore commits nothing and lifts the write pause.
# The non-superuser target role can't CREATE EXTENSION postgis in a database without it.
sql gtgt "CREATE ROLE appuser LOGIN PASSWORD '${PW}'" > /dev/null
sql gtgt "CREATE DATABASE app2 OWNER appuser TEMPLATE template0" > /dev/null
TGT_DB=app2 TGT_USER=appuser check "failed restore rolls back" fail "nothing was committed" -- run_job "$GIS_NEW" upgrade gsrc gtgt
equals "failed restore: target still empty" "$(sql gtgt "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'" app2)" 0
equals "failed restore: source writable" "$(sql gsrc "INSERT INTO public.places (geom) VALUES (NULL) RETURNING 'ok'")" ok

check "PostGIS upgrade copies and verifies" pass "public.places: 301 rows" -- run_job "$GIS_NEW" upgrade gsrc gtgt
equals "PostGIS: geometry works on the target" "$(sql gtgt "SELECT count(*) FROM public.places WHERE ST_X(geom) > -123")" 300

exit "$FAILED"
