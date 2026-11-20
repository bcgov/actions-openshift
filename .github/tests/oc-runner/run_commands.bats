#!/usr/bin/env bats
# oc-runner commands block: failure annotation and verbose xtrace, no cluster

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../oc-runner/scripts/run_commands.sh"
  export SCRIPT
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
  export COMMANDS_TIMEOUT=10s
  export DEBUG=false
}

run_script() {
  run bash -c '"$SCRIPT" 2>&1'
}

@test "commands failure reports the annotation and exit code" {
  export COMMANDS='exit 7'
  run_script
  [ "$status" -eq 7 ]
  [[ "$output" == *"::error title=bcgov/actions-openshift/oc-runner: commands input failed::"* ]]
  [[ "$output" == *"[bcgov/actions-openshift/oc-runner] commands block failed with exit code 7."* ]]
  grep -q 'Exit code: 7' "$GITHUB_STEP_SUMMARY"
}

@test "debug mode prints xtrace" {
  export DEBUG=true
  export COMMANDS='echo hello-from-commands'
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::[bcgov/actions-openshift/oc-runner] Debug mode enabled"* ]]
  [[ "$output" == *"echo hello-from-commands"* ]]
  [[ "$output" == *"+"*"echo hello-from-commands"* ]]
}

@test "timeout input firing reports the timeout" {
  export COMMANDS_TIMEOUT=1s
  export COMMANDS='sleep 5'
  run_script
  [ "$status" -eq 124 ]
  [[ "$output" == *"::error title=bcgov/actions-openshift/oc-runner: commands timed out::"* ]]
  [[ "$output" == *"commands exceeded timeout 1s."* ]]
}

@test "a command exiting 124 by itself is not reported as the timeout input" {
  export COMMANDS='timeout 1s sleep 5'
  run_script
  [ "$status" -eq 124 ]
  [[ "$output" != *"commands exceeded timeout"* ]]
  [[ "$output" == *"Exit code 124 came from a command inside the commands block"* ]]
  [[ "$output" == *"commands block failed with exit code 124."* ]]
  grep -q 'Exit code: 124' "$GITHUB_STEP_SUMMARY"
}

@test "a command exiting 124 just before the timeout input is not reported as the timeout" {
  export COMMANDS_TIMEOUT=2s
  export COMMANDS='sleep 1.8; exit 124'
  run_script
  [ "$status" -eq 124 ]
  [[ "$output" != *"commands exceeded timeout"* ]]
  [[ "$output" == *"commands block failed with exit code 124."* ]]
}

@test "timeout input with a leading zero still works" {
  export COMMANDS_TIMEOUT=08s
  export COMMANDS='echo ok'
  run_script
  [ "$status" -eq 0 ]
}

@test "commands output under the limit is passed on" {
  export COMMANDS='echo small-value >> "$GITHUB_OUTPUT"'
  run_script
  [ "$status" -eq 0 ]
  grep -q '^small-value$' "$GITHUB_OUTPUT"
}

@test "commands output over the limit fails clearly and writes nothing" {
  export COMMANDS='head -c 524289 /dev/zero | tr "\\0" a >> "$GITHUB_OUTPUT"'
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=bcgov/actions-openshift/oc-runner: commands output too large::"* ]]
  [[ "$output" == *"the limit is 524288 bytes"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "connect retry: success runs the block once" {
  export CONNECT_RETRY_DELAY=0
  export COMMANDS='echo run >> "$BATS_TEST_TMPDIR/runs"'
  run_script
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/runs")" -eq 1 ]
  [[ "$output" != *"retrying commands"* ]]
}

@test "connect retry: other failures are not retried and keep their exit code" {
  export CONNECT_RETRY_DELAY=0
  export COMMANDS='echo run >> "$BATS_TEST_TMPDIR/runs"; echo "Error: UPGRADE FAILED: x509: certificate signed by unknown authority" >&2; exit 3'
  run_script
  [ "$status" -eq 3 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/runs")" -eq 1 ]
  [[ "$output" != *"retrying commands"* ]]
  [[ "$output" == *"commands block failed with exit code 3."* ]]
}

@test "connect retry: a connect timeout is retried once, then success" {
  export CONNECT_RETRY_DELAY=0
  export COMMANDS='echo run >> "$BATS_TEST_TMPDIR/runs"
echo "attempt-output" >> "$GITHUB_OUTPUT"
if [ ! -e "$BATS_TEST_TMPDIR/marker" ]; then
  touch "$BATS_TEST_TMPDIR/marker"
  echo "Unable to connect to the server: dial tcp 142.34.194.119:6443: i/o timeout" >&2
  exit 1
fi'
  run_script
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/runs")" -eq 2 ]
  [[ "$output" == *"::warning title=bcgov/actions-openshift/oc-runner: retrying commands::"*"exit code 1"*"running the whole block once more in 0s."* ]]
  # Only the retry's output is passed on
  [ "$(grep -c '^attempt-output$' "$GITHUB_OUTPUT")" -eq 1 ]
}

@test "connect retry: a second connect timeout fails with its exit code" {
  export CONNECT_RETRY_DELAY=0
  export COMMANDS='echo run >> "$BATS_TEST_TMPDIR/runs"; echo "Error: Kubernetes cluster unreachable: Get \"https://api.silver.devops.gov.bc.ca:6443/version\": dial tcp 142.34.194.119:6443: i/o timeout" >&2; exit 5'
  run_script
  [ "$status" -eq 5 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/runs")" -eq 2 ]
  [ "$(grep -c 'retrying commands' <<< "$output")" -eq 1 ]
  [[ "$output" == *"commands block failed with exit code 5."* ]]
}
