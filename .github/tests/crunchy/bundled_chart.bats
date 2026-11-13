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

@test "pgBouncer service.type renders configured type" {
  CHART="${BATS_TEST_DIRNAME}/../../../crunchy/charts/crunchy"
  VALUES="${BATS_TEST_DIRNAME}/../../../crunchy/values.yml"
  for svc_type in ClusterIP NodePort; do
    helm template smoke "$CHART" --values "$VALUES" \
      --set-string "crunchy.proxy.pgBouncer.service.type=${svc_type}" > "${BATS_TEST_TMPDIR}/${svc_type}.yaml"
    actual="$(yq -r 'select(.kind == "PostgresCluster") | .spec.proxy.pgBouncer.service.type' "${BATS_TEST_TMPDIR}/${svc_type}.yaml")"
    [ "$actual" = "$svc_type" ]
  done
}

@test "pgBouncer service.type defaults to ClusterIP when service map is omitted" {
  CHART="${BATS_TEST_DIRNAME}/../../../crunchy/charts/crunchy"
  VALUES="${BATS_TEST_DIRNAME}/../../../crunchy/values.yml"
  yq 'del(.crunchy.proxy.pgBouncer.service)' "$VALUES" > "${BATS_TEST_TMPDIR}/values-noservice.yml"
  helm template smoke "$CHART" --values "${BATS_TEST_TMPDIR}/values-noservice.yml" > "${BATS_TEST_TMPDIR}/default.yaml"
  actual="$(yq -r 'select(.kind == "PostgresCluster") | .spec.proxy.pgBouncer.service.type' "${BATS_TEST_TMPDIR}/default.yaml")"
  [ "$actual" = "ClusterIP" ]
}
