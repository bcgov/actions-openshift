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
    DRY_RUN HELM_UPGRADE_RC
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
  grep -q "^helm upgrade --dry-run=server --hide-secret --install pg-test" "${STUB_LOG}"
  refute_call "^helm upgrade --install --wait"
  refute_call "^oc "
}

@test "dry_run does not self-heal a stuck release" {
  HELM_STATUS=pending-upgrade SELF_HEAL_STUCK_RELEASES=true DRY_RUN=true deploy
  [ "$status" -eq 0 ]
  grep -q "^helm upgrade --dry-run=server --hide-secret --install pg-test" "${STUB_LOG}"
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

