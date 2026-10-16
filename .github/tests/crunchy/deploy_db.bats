#!/usr/bin/env bats
# deploy_db.sh release-status handling, with stubbed helm and oc (needs jq and yq)

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../crunchy/scripts/deploy_db.sh"
  CHART="${BATS_TEST_TMPDIR}/chart"
  cp -r "${BATS_TEST_DIRNAME}/../../../crunchy/charts/crunchy" "${CHART}"
  export STUB_LOG="${BATS_TEST_TMPDIR}/calls.log"
  : > "${STUB_LOG}"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  # helm status prints HELM_STATUS as JSON, or fails when unset (no release)
  cat > "${BATS_TEST_TMPDIR}/bin/helm" <<'STUB'
#!/bin/bash
echo "helm $*" >> "${STUB_LOG}"
if [ "$1" = "upgrade" ] && [ -n "${HELM_UPGRADE_RC:-}" ]; then
  exit "${HELM_UPGRADE_RC}"
fi
if [ "$1" = "status" ]; then
  [ -n "${HELM_STATUS:-}" ] || exit 1
  echo "{\"info\":{\"status\":\"${HELM_STATUS}\"}}"
fi
STUB
  # oc get reports the db instance ready so the wait loop ends
  cat > "${BATS_TEST_TMPDIR}/bin/oc" <<'STUB'
#!/bin/bash
echo "oc $*" >> "${STUB_LOG}"
if [ "$1" = "get" ]; then
  echo '{"status":{"instances":[{"name":"db","readyReplicas":1}]}}'
fi
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/helm" "${BATS_TEST_TMPDIR}/bin/oc"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  unset HELM_STATUS SELF_HEAL_STUCK_RELEASES VALUES_URL PVC_SIZE STORAGE_CLASS \
    POSTGRES_VERSION REPLICAS CPU_REQUEST MEMORY_REQUEST ROUTE_ENABLED ROUTE_HOST \
    DRY_RUN HELM_UPGRADE_RC STANDBY_ENABLED STANDBY_REPO_NAME SHUTDOWN CUSTOM_PGUSER_PASSWORD
}

deploy() {
  run "${SCRIPT}" "${CHART}" "" app pg-test false
}

# Fails when the stub log has a matching call (errexit ignores `! grep` before the last line)
refute_call() {
  if grep -q "$1" "${STUB_LOG}"; then
    echo "unexpected call: $1"
    return 1
  fi
}

@test "not triggered, deployed release: skips upgrade" {
  HELM_STATUS=deployed deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"already deployed, triggers did not fire"* ]]
  refute_call "^helm upgrade"
}

@test "not triggered, no release: deploys" {
  deploy
  [ "$status" -eq 0 ]
  grep -q "^helm upgrade --install --wait pg-test" "${STUB_LOG}"
}

@test "not triggered, stuck release, self-heal: purges then deploys" {
  HELM_STATUS=pending-upgrade SELF_HEAL_STUCK_RELEASES=true deploy
  [ "$status" -eq 0 ]
  grep -q "^helm uninstall pg-test" "${STUB_LOG}"
  grep -q "^oc delete secret -l owner=helm,name=pg-test" "${STUB_LOG}"
  grep -q "^oc delete postgrescluster.postgres-operator.crunchydata.com/pg-test-crunchy" "${STUB_LOG}"
  grep -q "^helm upgrade --install --wait pg-test" "${STUB_LOG}"
}

@test "not triggered, stuck release, no self-heal: attempts upgrade, no purge" {
  HELM_STATUS=failed deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not in a deployed state"* ]]
  refute_call "^helm uninstall"
  refute_call "^oc delete"
  grep -q "^helm upgrade --install --wait pg-test" "${STUB_LOG}"
}

@test "dry_run still renders when the release is already deployed" {
  HELM_STATUS=deployed DRY_RUN=true deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping database ready check"* ]]
  [[ "$output" != *"already deployed, triggers did not fire"* ]]
  grep -q "^helm upgrade --dry-run=server --hide-secret --install --wait pg-test" "${STUB_LOG}"
  refute_call "^helm upgrade --install --wait pg-test"
  refute_call "^oc "
}

@test "dry_run does not self-heal a stuck release" {
  HELM_STATUS=pending-upgrade SELF_HEAL_STUCK_RELEASES=true DRY_RUN=true deploy
  [ "$status" -eq 0 ]
  grep -q "^helm upgrade --dry-run=server --hide-secret --install --wait pg-test" "${STUB_LOG}"
  refute_call "^helm uninstall"
  refute_call "^oc "
}

@test "dry_run helm failure is not treated as success" {
  DRY_RUN=true HELM_UPGRADE_RC=1 deploy
  [ "$status" -eq 1 ]
  refute_call "^oc "
}

@test "readiness check succeeds when instance name is not db" {
  cat > "${BATS_TEST_TMPDIR}/bin/oc" <<'STUB'
#!/bin/bash
echo "oc $*" >> "${STUB_LOG}"
if [ "$1" = "get" ]; then
  echo '{"status":{"instances":[{"name":"primary","readyReplicas":1}]}}'
fi
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/oc"
  deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Crunchy DB instance is ready."* ]]
}

@test "standby_enabled without S3 fails" {
  STANDBY_ENABLED=true deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"standby_enabled requires s3"* ]]
}

@test "standby_enabled with S3 deploys standby sets" {
  STANDBY_ENABLED=true run "${SCRIPT}" "${CHART}" "" app pg-test true ak sk bucket endpoint.example
  [ "$status" -eq 0 ]
  grep -q 'crunchy.standby.enabled=true' "${STUB_LOG}"
  grep -q 'crunchy.standby.repoName=repo2' "${STUB_LOG}"
  grep -q 'crunchy.pgBackRest.s3.enabled=true' "${STUB_LOG}"
}

@test "shutdown input: waits for zero ready replicas" {
  cat > "${BATS_TEST_TMPDIR}/bin/oc" <<'STUB'
#!/bin/bash
echo "oc $*" >> "${STUB_LOG}"
if [ "$1" = "get" ]; then
  echo '{"status":{"instances":[{"name":"db","readyReplicas":0}]}}'
fi
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/oc"
  SHUTDOWN=true deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Crunchy DB is shut down"* ]]
}

@test "shutdown via values_file: waits for zero ready replicas" {
  cat > "${BATS_TEST_TMPDIR}/bin/oc" <<'STUB'
#!/bin/bash
echo "oc $*" >> "${STUB_LOG}"
if [ "$1" = "get" ]; then
  echo '{"status":{"instances":[{"name":"db","readyReplicas":0}]}}'
fi
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/oc"
  VALUES_SRC="${BATS_TEST_TMPDIR}/shutdown-values.yml"
  cp "${BATS_TEST_DIRNAME}/../../../crunchy/values.yml" "${VALUES_SRC}"
  yq -i '.crunchy.shutdown = true' "${VALUES_SRC}"
  cat > "${BATS_TEST_TMPDIR}/bin/curl" <<STUB
#!/bin/bash
echo "curl \$*" >> "${STUB_LOG}"
out=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "-o" ]; then out="\$2"; shift 2; continue; fi
  shift
done
cp "${VALUES_SRC}" "\${out}"
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/curl"
  run "${SCRIPT}" "${CHART}" "https://example.com/values-shutdown.yml" app pg-test true
  [ "$status" -eq 0 ]
  [[ "$output" == *"Crunchy DB is shut down"* ]]
}

@test "custom password with spaces/punctuation patches existing Secret via oc" {
  PASS='alpha beta,x!y'
  cat > "${BATS_TEST_TMPDIR}/bin/oc" <<'STUB'
#!/bin/bash
echo "oc $*" >> "${STUB_LOG}"
if [ "$1" = "get" ] && [[ "$*" == *"PostgresCluster/"* ]]; then
  echo '{"status":{"instances":[{"name":"db","readyReplicas":1}]}}'
  exit 0
fi
if [ "$1" = "get" ] && [[ "$*" == *secret/*pguser* ]]; then
  exit 0
fi
if [ "$1" = "project" ]; then
  echo "test-ns"
  exit 0
fi
if [ "$1" = "patch" ]; then
  # Record patch file contents for assertion
  while [ $# -gt 0 ]; do
    if [ "$1" = "--patch-file" ]; then
      cp "$2" "${STUB_LOG}.patch"
      break
    fi
    shift
  done
  exit 0
fi
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/oc"
  # jq needed for patch builder
  command -v jq >/dev/null
  CUSTOM_PGUSER_PASSWORD="$PASS" deploy
  [ "$status" -eq 0 ]
  grep -q "Patching password on existing Secret" <<< "$output"
  grep -q "oc patch secret/pg-test-crunchy-pguser-app" "${STUB_LOG}"
  # Assert literal password survived into the patch JSON
  grep -q "$PASS" "${STUB_LOG}.patch"
  # Helm must not receive --set-file / unquoted password fragments
  ! grep -q -- '--set-file' "${STUB_LOG}"
  ! grep -q 'alpha beta' "${STUB_LOG}"
}

@test "custom password creates Secret when missing (outside Helm)" {
  cat > "${BATS_TEST_TMPDIR}/bin/oc" <<'STUB'
#!/bin/bash
echo "oc $*" >> "${STUB_LOG}"
if [ "$1" = "get" ] && [[ "$*" == *"PostgresCluster/"* ]]; then
  echo '{"status":{"instances":[{"name":"db","readyReplicas":1}]}}'
  exit 0
fi
if [ "$1" = "get" ] && [[ "$*" == *secret/*pguser* ]]; then
  exit 1
fi
if [ "$1" = "project" ]; then echo "test-ns"; exit 0; fi
if [ "$1" = "create" ]; then
  # Emit a minimal Secret for the label|apply pipeline; record --from-file path
  while [ $# -gt 0 ]; do
    if [[ "$1" == --from-file=password=* ]]; then
      src="${1#--from-file=password=}"
      cp "$src" "${STUB_LOG}.pass"
    fi
    shift
  done
  cat <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: pg-test-crunchy-pguser-app
YAML
  exit 0
fi
if [ "$1" = "label" ]; then
  cat
  exit 0
fi
if [ "$1" = "apply" ]; then
  if [ ! -t 0 ]; then cat > "${STUB_LOG}.apply"; fi
  exit 0
fi
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/oc"
  CUSTOM_PGUSER_PASSWORD='s3cret, with spaces!' deploy
  [ "$status" -eq 0 ]
  grep -q "Creating pguser Secret" <<< "$output"
  grep -q "oc create secret generic pg-test-crunchy-pguser-app" "${STUB_LOG}"
  grep -q 's3cret, with spaces!' "${STUB_LOG}.pass"
  grep -q "oc apply" "${STUB_LOG}"
  ! grep -q -- '--set-file' "${STUB_LOG}"
}

@test "dry_run skips custom password Secret mutation" {
  CUSTOM_PGUSER_PASSWORD='should-not-apply' DRY_RUN=true deploy
  [ "$status" -eq 0 ]
  refute_call "^oc patch"
  refute_call "^oc create secret"
  refute_call "^oc apply"
}
