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
