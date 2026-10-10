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
  export ENABLE_VERBOSE=false
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

@test "verbose mode prints xtrace" {
  export ENABLE_VERBOSE=true
  export COMMANDS='echo hello-from-commands'
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::[bcgov/actions-openshift/oc-runner] Verbose mode enabled"* ]]
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
