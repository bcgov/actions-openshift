#!/usr/bin/env bats
# A normal crunchy run deploys the chart in this repo, not bcgov/action-crunchy@main

setup() {
  ACTION="${BATS_TEST_DIRNAME}/../../../crunchy/action.yml"
}

@test "default run uses the bundled chart and does not check out action-crunchy" {
  if grep -q 'bcgov/action-crunchy' "$ACTION"; then
    echo "crunchy/action.yml still names bcgov/action-crunchy"
    return 1
  fi
  default="$(yq -r '.inputs.repository.default' "$ACTION")"
  [ -z "$default" ]
  [ "$(grep -c 'uses: actions/checkout@' "$ACTION")" -eq 1 ]
  grep -A1 "if: inputs.repository != ''" "$ACTION" | grep -q 'uses: actions/checkout@'
  grep -q 'GITHUB_ACTION_PATH}/charts/crunchy' "$ACTION"
  grep -F "trap 'rm -rf \"\${DIRECTORY}\"' EXIT" "$ACTION"
}

@test "standby.enabled renders PostgresCluster standby block" {
  CHART="${BATS_TEST_DIRNAME}/../../../crunchy/charts/crunchy"
  VALUES="${BATS_TEST_DIRNAME}/../../../crunchy/values.yml"
  helm template smoke "$CHART" --values "$VALUES" \
    --set crunchy.standby.enabled=true \
    --set-string crunchy.standby.repoName=repo2 > "${BATS_TEST_TMPDIR}/standby.yaml"
  grep -q 'standby:' "${BATS_TEST_TMPDIR}/standby.yaml"
  grep -q 'repoName: repo2' "${BATS_TEST_TMPDIR}/standby.yaml"
}

@test "wal_retrieve_retry_interval renders in Patroni parameters" {
  CHART="${BATS_TEST_DIRNAME}/../../../crunchy/charts/crunchy"
  VALUES="${BATS_TEST_DIRNAME}/../../../crunchy/values.yml"
  helm template smoke "$CHART" --values "$VALUES" > "${BATS_TEST_TMPDIR}/patroni.yaml"
  grep -q 'wal_retrieve_retry_interval: 30000' "${BATS_TEST_TMPDIR}/patroni.yaml"
}

@test "customPassword is not rendered as a Helm Secret" {
  CHART="${BATS_TEST_DIRNAME}/../../../crunchy/charts/crunchy"
  VALUES="${BATS_TEST_DIRNAME}/../../../crunchy/values.yml"
  helm template smoke "$CHART" --values "$VALUES" \
    --set-string crunchy.pgUser.customPassword=shared-pass > "${BATS_TEST_TMPDIR}/with.yaml"
  # Password Secrets are applied by deploy_db.sh outside Helm
  ! grep -q 'password: "shared-pass"' "${BATS_TEST_TMPDIR}/with.yaml"
}

@test "pgBackRest.pvc defaults to enabled when pvc.enabled key is omitted" {
  CHART="${BATS_TEST_DIRNAME}/../../../crunchy/charts/crunchy"
  VALUES="${BATS_TEST_DIRNAME}/../../../crunchy/values.yml"
  yq 'del(.crunchy.pgBackRest.pvc.enabled)' "$VALUES" > "${BATS_TEST_TMPDIR}/values-no-pvc-enabled.yml"
  helm template smoke "$CHART" --values "${BATS_TEST_TMPDIR}/values-no-pvc-enabled.yml" > "${BATS_TEST_TMPDIR}/default-pvc.yaml"
  grep -q 'name: repo1' "${BATS_TEST_TMPDIR}/default-pvc.yaml"
  grep -q 'repo1-retention-full:' "${BATS_TEST_TMPDIR}/default-pvc.yaml"
  grep -q 'repoHost:' "${BATS_TEST_TMPDIR}/default-pvc.yaml"
}

@test "pgBackRest.pvc.enabled=false with s3.enabled=true omits repo1 and repoHost" {
  CHART="${BATS_TEST_DIRNAME}/../../../crunchy/charts/crunchy"
  VALUES="${BATS_TEST_DIRNAME}/../../../crunchy/values.yml"
  helm template smoke "$CHART" --values "$VALUES" \
    --set crunchy.pgBackRest.pvc.enabled=false \
    --set crunchy.pgBackRest.s3.enabled=true \
    --set-string crunchy.pgBackRest.s3.bucket=test-bucket \
    --set-string crunchy.pgBackRest.s3.endpoint=s3.example.com \
    --set-string crunchy.pgBackRest.s3.accessKey=ak \
    --set-string crunchy.pgBackRest.s3.secretKey=sk \
    --set crunchy.pgBackRest.manual.enabled=true > "${BATS_TEST_TMPDIR}/s3-only.yaml"
  ! grep -q 'name: repo1' "${BATS_TEST_TMPDIR}/s3-only.yaml"
  ! grep -q 'repo1-retention-full:' "${BATS_TEST_TMPDIR}/s3-only.yaml"
  ! grep -q 'repoHost:' "${BATS_TEST_TMPDIR}/s3-only.yaml"
  grep -q 'name: repo2' "${BATS_TEST_TMPDIR}/s3-only.yaml"
  grep -q 'repo2-retention-full:' "${BATS_TEST_TMPDIR}/s3-only.yaml"
  grep -q 'repoName: repo2' "${BATS_TEST_TMPDIR}/s3-only.yaml"
}

@test "pgBackRest.enabled=true fails when both pvc.enabled and s3.enabled are false" {
  CHART="${BATS_TEST_DIRNAME}/../../../crunchy/charts/crunchy"
  VALUES="${BATS_TEST_DIRNAME}/../../../crunchy/values.yml"
  run helm template smoke "$CHART" --values "$VALUES" \
    --set crunchy.pgBackRest.pvc.enabled=false \
    --set crunchy.pgBackRest.s3.enabled=false
  [ "$status" -ne 0 ]
  [[ "$output" == *"crunchy.pgBackRest.enabled is true, but both pvc.enabled and s3.enabled are false"* ]]
}
