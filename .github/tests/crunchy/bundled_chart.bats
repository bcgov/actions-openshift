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

@test "customPassword renders pguser Secret; empty does not" {
  CHART="${BATS_TEST_DIRNAME}/../../../crunchy/charts/crunchy"
  VALUES="${BATS_TEST_DIRNAME}/../../../crunchy/values.yml"

  helm template smoke "$CHART" --values "$VALUES" \
    --set-string crunchy.pgUser.customPassword=shared-pass > "${BATS_TEST_TMPDIR}/with.yaml"
  grep -q 'pguser-app' "${BATS_TEST_TMPDIR}/with.yaml"
  grep -q 'password: "shared-pass"' "${BATS_TEST_TMPDIR}/with.yaml"
  grep -q 'postgres-operator.crunchydata.com/pguser: app' "${BATS_TEST_TMPDIR}/with.yaml"

  helm template smoke "$CHART" --values "$VALUES" > "${BATS_TEST_TMPDIR}/without.yaml"
  if grep -q 'pguser-app' "${BATS_TEST_TMPDIR}/without.yaml"; then
    # Operator-managed users may still reference pguser elsewhere; the Secret we add is only when customPassword is set
    if grep -A5 'kind: Secret' "${BATS_TEST_TMPDIR}/without.yaml" | grep -q 'password: "'; then
      echo "unexpected password Secret without customPassword"
      return 1
    fi
  fi
  # Our custom Secret stringData password must be absent
  ! grep -q 'password: "shared-pass"' "${BATS_TEST_TMPDIR}/without.yaml"
}
