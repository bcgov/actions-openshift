#!/usr/bin/env bats
# .github/tests/pg-upgrade/quota.sh: sizing the large-dataset test from quota JSON
bats_require_minimum_version 1.5.0

setup() {
  export SCRIPT="${BATS_TEST_DIRNAME}/quota.sh"
  Q="${BATS_TEST_TMPDIR}/quota.json"
  L="${BATS_TEST_TMPDIR}/limits.json"
  echo '{"items":[]}' > "$Q"
  echo '{"items":[]}' > "$L"
}

quota() { # hard-json used-json
  jq -n --argjson h "$1" --argjson u "$2" '{items: [{status: {hard: $h, used: $u}}]}' > "$Q"
}
limitrange() { # default-json
  jq -n --argjson d "$1" '{items: [{spec: {limits: [{type: "Pod", max: {memory: "1Ti"}}, {type: "Container", default: $d}]}}]}' > "$L"
}

@test "no quota or limits: the largest scale" {
  run --separate-stderr "$SCRIPT" "$Q" "$L"
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
}

@test "a container ephemeral-storage limit caps the scale" {
  limitrange '{"ephemeral-storage": "1Gi"}'
  run --separate-stderr "$SCRIPT" "$Q" "$L"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
}

@test "quota headroom caps the scale, in any unit" {
  quota '{"limits.ephemeral-storage": "10G", "limits.memory": "32Gi", "pods": "50"}' '{"limits.ephemeral-storage": "7000000Ki", "limits.memory": "20480Mi", "pods": "10"}'
  run --separate-stderr "$SCRIPT" "$Q" "$L"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
}

@test "too little ephemeral storage fails with a Fix line" {
  limitrange '{"ephemeral-storage": "512Mi"}'
  run "$SCRIPT" "$Q" "$L"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::The namespace's ephemeral storage is too small"* ]]
  [[ "$output" == *"Fix: "* ]]
}

@test "too little memory fails with a Fix line" {
  quota '{"limits.memory": "4Gi"}' '{"limits.memory": "3Gi"}'
  run "$SCRIPT" "$Q" "$L"
  [ "$status" -ne 0 ]
  [[ "$output" == *"1024Mi of memory limits free; the test needs 2048Mi"* ]]
}

@test "too few pods fails with a Fix line" {
  quota '{"count/pods": "20", "pods": "30"}' '{"count/pods": "18", "pods": "10"}'
  run "$SCRIPT" "$Q" "$L"
  [ "$status" -ne 0 ]
  [[ "$output" == *"room for 2 more pod(s)"* ]]
}

@test "unreadable quota JSON fails with a Fix line" {
  echo 'Unable to connect' > "$Q"
  run "$SCRIPT" "$Q" "$L"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not read the namespace ResourceQuota"* ]]
}
