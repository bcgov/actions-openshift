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
