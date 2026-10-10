#!/usr/bin/env bats
# pg-upgrade/scripts/run.sh with a stub oc: input checks, objects created, result and cleanup. No cluster.

setup() {
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../pg-upgrade/scripts/run.sh"
  export ACTION_PATH="${BATS_TEST_DIRNAME}/../../../pg-upgrade"
  export STATE="${BATS_TEST_TMPDIR}/state"
  mkdir -p "$STATE" "${BATS_TEST_TMPDIR}/bin"
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
  : > "$GITHUB_OUTPUT"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export MODE=upgrade SOURCE=app-test-database TARGET=app-test-database-17 SECRET=app-test-database
  export IMAGE=postgres:17.6 APP_LABEL=app-test POLL=0 GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1
  export SERVICES="app-test-database app-test-database-17" JOB_RESULT=succeeded
  # Stub oc: services from $SERVICES, created objects saved as JSON in $STATE, logs every call
  cat > "${BATS_TEST_TMPDIR}/bin/oc" <<'STUB'
#!/usr/bin/env bash
echo "oc $*" >> "${STATE}/calls"
case "$1 $2" in
  "get service")
    [ -z "${OC_FAIL_SERVICE:-}" ] || { echo "Unable to connect to the server" >&2; exit 1; }
    for s in $SERVICES; do
      if [ "$s" = "$3" ]; then
        if [ "${4:-}" = "-o" ] && [ "$5" = json ]; then echo "{\"spec\":{\"selector\":{\"deployment\":\"$3\"}}}"; else echo "service/$3"; fi
      fi
    done ;;
  "get configmap") [ -f "${STATE}/marker" ] && cat "${STATE}/marker"; true ;;
  "create -f")
    obj="$(cat)"; kind="$(jq -r .kind <<< "$obj")"; name="$(jq -r .metadata.name <<< "$obj")"
    echo "$obj" > "${STATE}/${kind}-${name}.json"
    [ "$kind" = ConfigMap ] && jq -r .data.status <<< "$obj" > "${STATE}/marker"; true ;;
  "get pods") echo "pod/job-pod" ;;
  "get pod/job-pod")
    case "$4" in *phase*) echo Running ;; *waiting*) echo "${WAITING:-}" ;; esac ;;
  "logs -f") echo "job log line" ;;
  "get job")
    case "$5" in
      *succeeded*) [ "$JOB_RESULT" = succeeded ] && echo 1; true ;;
      *failed*) [ "$JOB_RESULT" = failed ] && echo 1; true ;;
      *conditions*) echo "BackoffLimitExceeded" ;;
    esac ;;
  "patch configmap") echo done > "${STATE}/marker" ;;
  "delete configmap") rm -f "${STATE}/marker" ;;
  "delete networkpolicy") echo "$3" >> "${STATE}/deleted-np" ;;
  "delete job") echo "$3" >> "${STATE}/deleted-job" ;;
esac
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/oc"
}

run_script() {
  run bash -c '"$SCRIPT" 2>&1'
}

job_json() { cat "${STATE}"/Job-*.json; }

@test "upgrade creates the lock, network policies and Job, then reports upgraded" {
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"Started Job pgup-upgrade-42-1-"* ]]
  [[ "$output" == *"job log line"* ]]
  grep -qx 'result=upgraded' "$GITHUB_OUTPUT"
  [ "$(cat "${STATE}/marker")" = done ]
  [ "$(job_json | jq -r '.spec.template.spec.containers[0].image')" = postgres:17.6 ]
  [ "$(job_json | jq -r '.spec.backoffLimit')" = 0 ]
  [ "$(job_json | jq -r '.spec.activeDeadlineSeconds')" = 1740 ]
  [ "$(job_json | jq -r '.metadata.labels.app')" = app-test ]
  [ "$(job_json | jq -r '[.spec.template.spec.containers[0].env[] | select(.name == "TGT_PASSWORD")][0].valueFrom.secretKeyRef.key')" = database-password ]
  # Passwords only ever come from secretKeyRef, never as values
  [ "$(job_json | jq '[.spec.template.spec.containers[0].env[] | select(.name | test("PASSWORD")) | select(.value)] | length')" = 0 ]
  [ "$(cat "${STATE}"/NetworkPolicy-*-src.json | jq -r '.spec.podSelector.matchLabels.deployment')" = app-test-database ]
  [ "$(cat "${STATE}"/NetworkPolicy-*-tgt.json | jq -r '.spec.podSelector.matchLabels.deployment')" = app-test-database-17 ]
  [ "$(wc -l < "${STATE}/deleted-np")" -eq 2 ]
}

@test "no source Service is a skip, not a failure" {
  export SERVICES="app-test-database-17"
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::No Service app-test-database"* ]]
  grep -qx 'result=skipped' "$GITHUB_OUTPUT"
  ! ls "${STATE}"/Job-*.json 2> /dev/null
}

@test "a finished upgrade is not repeated" {
  echo done > "${STATE}/marker"
  run_script
  [ "$status" -eq 0 ]
  grep -qx 'result=already-upgraded' "$GITHUB_OUTPUT"
  ! ls "${STATE}"/Job-*.json 2> /dev/null
}

@test "a running or interrupted upgrade blocks a second one" {
  echo running > "${STATE}/marker"
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::ConfigMap app-test-database-17-pg-upgrade says an upgrade"* ]]
  [[ "$output" == *"Fix: "* ]]
  [ "$(cat "${STATE}/marker")" = running ]
}

@test "a failed Job fails the step, releases the lock and removes the network policies" {
  export JOB_RESULT=failed
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::Job pgup-upgrade-42-1-"*"failed (upgrade)"* ]]
  [ ! -f "${STATE}/marker" ]
  [ "$(wc -l < "${STATE}/deleted-np")" -eq 2 ]
}

@test "an image pull error fails fast, removes the Job and releases the lock" {
  export WAITING=ImagePullBackOff
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"can't pull image postgres:17.6"* ]]
  grep -q '^pgup-upgrade-42-1-' "${STATE}/deleted-job"
  [ ! -f "${STATE}/marker" ]
}

@test "an API error looking up the source fails instead of skipping" {
  export OC_FAIL_SERVICE=1
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::Could not read Service app-test-database from OpenShift."* ]]
  ! grep -q 'result=skipped' "$GITHUB_OUTPUT"
}

@test "missing target Service fails before anything is created" {
  export SERVICES="app-test-database"
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::Target Service app-test-database-17 not found."* ]]
  ! ls "${STATE}"/*.json 2> /dev/null
}

@test "rehearse needs no target and creates one network policy" {
  export MODE=rehearse TARGET=""
  run_script
  [ "$status" -eq 0 ]
  grep -qx 'result=rehearsed' "$GITHUB_OUTPUT"
  [ "$(ls "${STATE}"/NetworkPolicy-*.json | wc -l)" -eq 1 ]
  [ ! -f "${STATE}/marker" ]
  [ "$(job_json | jq '[.spec.template.spec.containers[0].env[] | select(.name | startswith("TGT_"))] | length')" = 0 ]
}

@test "rollback clears the record" {
  export MODE=rollback IMAGE=""
  echo done > "${STATE}/marker"
  run_script
  [ "$status" -eq 0 ]
  grep -qx 'result=rolled-back' "$GITHUB_OUTPUT"
  [ ! -f "${STATE}/marker" ]
}

@test "input checks fail with a Fix line" {
  local cases=(
    "MODE=migrate|Invalid mode 'migrate'."
    "IMAGE=image-registry.openshift-image-registry.svc:5000/openshift/postgresql:12|Unsupported image"
    "IMAGE=postgres|Unsupported image 'postgres'."
    "IMAGE=bitnami/postgresql:17|Unsupported image"
    "IMAGE=|image is required for mode upgrade."
    "TARGET=|Invalid target ''."
    "TARGET=app-test-database|source and target are both"
    "SOURCE=Bad_Name|Invalid source"
    "TIMEOUT=30|Invalid timeout '30'."
    "TIMEOUT=1m|timeout 1m is too short."
    "MEMORY_LIMIT=1G|Invalid memory_limit"
  )
  for c in "${cases[@]}"; do
    run env "${c%%|*}" bash -c '"$SCRIPT" 2>&1'
    [ "$status" -eq 1 ] || { echo "case ${c} exited ${status}"; return 1; }
    [[ "$output" == *"::error::${c#*|}"* ]] || { echo "case ${c}: ${output}"; return 1; }
    [[ "$output" == *"Fix: "* ]] || { echo "case ${c}: no Fix line"; return 1; }
  done
}

@test "official images are accepted, with or without docker.io and digests" {
  for img in postgres:18.0 docker.io/library/postgres:17-alpine postgis/postgis:17-3.5 \
    "docker.io/postgis/postgis:17-3.5@sha256:$(printf 'a%.0s' {1..64})"; do
    export IMAGE="$img"
    rm -rf "${STATE:?}"/*
    run_script
    [ "$status" -eq 0 ] || { echo "image ${img}: ${output}"; return 1; }
  done
}
