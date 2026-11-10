#!/usr/bin/env bats
# Exercise the real Summary script from probe-runner-reachability.yml

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/summarize-probe-results.sh"
  WORK="${BATS_TEST_TMPDIR}/work"
  mkdir -p "${WORK}/probes"
  cd "$WORK" || exit 1
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  export GITHUB_RUN_ID=42673406979
  export GITHUB_RUN_ATTEMPT=1
  : > "$GITHUB_STEP_SUMMARY"
}

write_probe() {
  local sample="$1" ip="$2" blocked="${3:-false}"
  local gold_api silver_api router silver_blocked=false
  if [ "$blocked" = true ]; then
    gold_api="000 000 000"
    silver_api="000 000 000"
    router="200 200 200"
    silver_blocked=true
  else
    gold_api="200 200 200"
    silver_api="200 200 200"
    router="200 200 200"
  fi
  jq -cn \
    --arg sample "${sample}" --arg ip "${ip}" \
    --arg gold_api "${gold_api}" --arg silver_api "${silver_api}" --arg silver_router "${router}" \
    --argjson api_blocked "${blocked}" \
    --argjson router_ok_while_api_blocked "${silver_blocked}" \
    '$ARGS.named' > "probes/probe-${sample}.json"
}

MISSING_NOTE="Missing samples mean results didn't come back, which is usually a GitHub job/runner hiccup and not an IP block, so re-run all jobs."

@test "complete samples pass, with no missing rows, count, note, or error" {
  write_probe 1 20.0.0.1
  write_probe 2 20.0.0.2
  write_probe 3 20.0.0.3
  run env EXPECTED_SAMPLES=3 "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -F '| 1 | 20.0.0.1 | 200 200 200 | 200 200 200 | 200 200 200 | false | false |' "$GITHUB_STEP_SUMMARY"
  grep -F '| 2 | 20.0.0.2 | 200 200 200 | 200 200 200 | 200 200 200 | false | false |' "$GITHUB_STEP_SUMMARY"
  grep -F '| 3 | 20.0.0.3 | 200 200 200 | 200 200 200 | 200 200 200 | false | false |' "$GITHUB_STEP_SUMMARY"
  grep -F 'Samples: 3, missing: 0, unique IPs: 3, API blocked: 0, router OK while API blocked: 0' "$GITHUB_STEP_SUMMARY"
  ! grep -F 'missing | no result / job never ran' "$GITHUB_STEP_SUMMARY"
  ! grep -F "$MISSING_NOTE" "$GITHUB_STEP_SUMMARY"
  [[ "$output" != *"$MISSING_NOTE"* ]]
  [[ "$output" != *'::error::'* ]]
  [[ "$output" != *'::warning::'* ]]
  [ "$(jq '.samples | map(.sample | tonumber) | sort | . == [1, 2, 3]' probe-results.json)" = true ]
  [ "$(jq '.samples | length' probe-results.json)" = 3 ]
  [ "$(jq '.run_id' probe-results.json)" = 42673406979 ]
  [ "$(jq '.run_attempt' probe-results.json)" = 1 ]
}

@test "missing samples get table rows, a missing count, the hiccup note, named error, and a failed exit" {
  write_probe 1 20.0.0.1
  write_probe 2 20.0.0.2 true
  write_probe 3 20.0.0.3
  write_probe 5 20.0.0.5
  # 4 is absent, standing in for a matrix job GitHub never created
  run env EXPECTED_SAMPLES=5 "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -F '| 1 | 20.0.0.1 | 200 200 200 | 200 200 200 | 200 200 200 | false | false |' "$GITHUB_STEP_SUMMARY"
  grep -F '| 2 | 20.0.0.2 | 000 000 000 | 000 000 000 | 200 200 200 | true | true |' "$GITHUB_STEP_SUMMARY"
  grep -F '| 3 | 20.0.0.3 | 200 200 200 | 200 200 200 | 200 200 200 | false | false |' "$GITHUB_STEP_SUMMARY"
  grep -F '| 4 | missing | no result / job never ran | - | - | - | - |' "$GITHUB_STEP_SUMMARY"
  grep -F '| 5 | 20.0.0.5 | 200 200 200 | 200 200 200 | 200 200 200 | false | false |' "$GITHUB_STEP_SUMMARY"
  grep -F 'Samples: 4, missing: 1, unique IPs: 4, API blocked: 1, router OK while API blocked: 1' "$GITHUB_STEP_SUMMARY"
  grep -F "$MISSING_NOTE" "$GITHUB_STEP_SUMMARY"
  # Note sits under the table, not merged into the API-blocked warning
  [[ "$output" == *"::warning::OpenShift API unreachable from 1 of 4 runner sample(s); recorded in the table above and in probe-results"* ]]
  [[ "$output" == *"::error::Incomplete probe record: expected samples 1-5, missing 4. Re-run all jobs to regenerate missing or expired samples. ${MISSING_NOTE}"* ]]
  [[ "$output" != *"::warning::"*"$MISSING_NOTE"* ]]
  # probe-results.json still lists only samples that came back
  [ "$(jq '.samples | map(.sample | tonumber) | sort | . == [1, 2, 3, 5]' probe-results.json)" = true ]
  [ "$(jq '.samples | length' probe-results.json)" = 4 ]
  [ "$(jq '[.samples[].ip] | index("missing")' probe-results.json)" = null ]
}

@test "several missing samples are named and do not invent probe-results rows" {
  write_probe 1 20.1.0.1
  write_probe 3 20.1.0.3
  write_probe 5 20.1.0.5
  run env EXPECTED_SAMPLES=5 "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -F '| 2 | missing | no result / job never ran | - | - | - | - |' "$GITHUB_STEP_SUMMARY"
  grep -F '| 4 | missing | no result / job never ran | - | - | - | - |' "$GITHUB_STEP_SUMMARY"
  grep -F 'Samples: 3, missing: 2, unique IPs: 3, API blocked: 0, router OK while API blocked: 0' "$GITHUB_STEP_SUMMARY"
  grep -F "$MISSING_NOTE" "$GITHUB_STEP_SUMMARY"
  [[ "$output" == *"::error::Incomplete probe record: expected samples 1-5, missing 2, 4. Re-run all jobs to regenerate missing or expired samples. ${MISSING_NOTE}"* ]]
  [[ "$output" != *'::warning::'* ]]
  [ "$(jq '.samples | map(.sample | tonumber) | sort | . == [1, 3, 5]' probe-results.json)" = true ]
}
