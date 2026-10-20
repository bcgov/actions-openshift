#!/usr/bin/env bats
# shared/inputs.sh: list, bool, enum and debug parsing

setup() {
  # shellcheck source=../../../shared/inputs.sh
  source "${BATS_TEST_DIRNAME}/../../../shared/inputs.sh"
}

@test "list: one item per line, or a single value" {
  [ "$(input_list triggers $'backend/\n\n frontend/ ')" = $'backend/\nfrontend/' ]
  [ "$(input_list triggers $'src/{a,b}/**\nc/')" = $'src/{a,b}/**\nc/' ]
  [ "$(input_list triggers 'backend/')" = 'backend/' ]
  [ "$(input_list triggers "'my path/'")" = 'my path/' ]
  [ -z "$(input_list triggers '')" ]
}

@test "list: comma separated line fails with a one-per-line example" {
  run input_list triggers 'backend/, frontend/'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid triggers input: backend/, frontend/"* ]]
  [[ "$output" == *"triggers takes one item per line, or a single value."* ]]
  [[ "$output" == *"%0A  triggers: |%0A    backend/%0A    frontend/"* ]]
  [[ "$output" == *"Multiline input syntax: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepswith" ]]
}

@test "list: other formats fail" {
  for raw in "('backend/' 'frontend/')" '["backend/", "frontend/"]' 'a b' 'a;b' 'a,b' \
    "$(printf "(\n'backend/'\n'frontend/'\n)")" $'a/\nb/, c/' $'a/\nb/ c/'; do
    run input_list triggers "$raw"
    [ "$status" -eq 1 ]
  done
}

@test "bool, enum and debug" {
  [ "$(input_bool dry_run TRUE false)" = true ]
  [ "$(input_bool dry_run '' true)" = true ]
  run input_bool dry_run yes false
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid dry_run input: yes"* ]]
  [ "$(input_enum mode Upgrade 'upgrade rehearse' upgrade)" = upgrade ]
  run input_enum mode x 'upgrade rehearse' upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"Use one of: upgrade, rehearse"* ]]
  [ "$(RUNNER_DEBUG= input_debug '')" = false ]
  [ "$(RUNNER_DEBUG=1 input_debug '')" = true ]
}
