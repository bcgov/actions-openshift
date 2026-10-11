#!/usr/bin/env bats
# pg-upgrade/scripts/oc_retry.sh: retries only calls that never reached the API

setup() {
  export STATE="${BATS_TEST_TMPDIR}/state"
  mkdir -p "$STATE" "${BATS_TEST_TMPDIR}/bin"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" OC_RETRY_DELAY=0
  # Stub oc: fails with $ERR for the first $FAILS calls, then echoes its args and stdin
  cat > "${BATS_TEST_TMPDIR}/bin/oc" <<'STUB'
#!/usr/bin/env bash
n=$(($(cat "${STATE}/n" 2> /dev/null || echo 0) + 1)); echo "$n" > "${STATE}/n"
if [ "$n" -le "${FAILS:-0}" ]; then echo "$ERR" >&2; exit 1; fi
echo "args: $*"
if [ ! -t 0 ]; then echo "stdin: $(cat)"; fi
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/oc"
  # shellcheck source=pg-upgrade/scripts/oc_retry.sh
  source "${BATS_TEST_DIRNAME}/../../../pg-upgrade/scripts/oc_retry.sh"
}

@test "a dial timeout is retried and stdin reaches exec -i on the retry" {
  FAILS=2 ERR='Unable to connect to the server: dial tcp 1.2.3.4:6443: i/o timeout'
  export FAILS ERR
  run oc exec -i pod/x -- psql -f - <<< "SELECT 1"
  [ "$status" -eq 0 ]
  [ "$(cat "${STATE}/n")" = 3 ]
  [[ "$output" == *"stdin: SELECT 1"* ]]
  [[ "$output" == *"retrying"* ]]
}

@test "create -f - keeps its stdin across retries" {
  FAILS=1 ERR='dial tcp 1.2.3.4:6443: connect: connection refused'
  export FAILS ERR
  run oc create -f - <<< '{"kind":"ConfigMap"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'stdin: {"kind":"ConfigMap"}'* ]]
}

@test "server errors are not retried" {
  FAILS=1 ERR='Error from server (Forbidden): pods is forbidden'
  export FAILS ERR
  run oc get pods
  [ "$status" -eq 1 ]
  [ "$(cat "${STATE}/n")" = 1 ]
  [[ "$output" == *Forbidden* ]]
}

@test "gives up after OC_RETRIES and returns the error" {
  FAILS=99 ERR='dial tcp 1.2.3.4:6443: i/o timeout' OC_RETRIES=3
  export FAILS ERR
  run oc get pods
  [ "$status" -eq 1 ]
  [ "$(cat "${STATE}/n")" = 3 ]
  [[ "$output" == *"i/o timeout"* ]]
}
