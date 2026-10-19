#!/usr/bin/env bats
# shared/inputs.sh: list, bool, enum and debug parsing

setup() {
  # shellcheck source=../../../shared/inputs.sh
  source "${BATS_TEST_DIRNAME}/../../../shared/inputs.sh"
}

@test "list: multiline, comma, JSON, single" {
  [ "$(input_list triggers $'backend/\n\n frontend/ ')" = $'backend/\nfrontend/' ]
  [ "$(input_list triggers 'backend/, frontend/')" = $'backend/\nfrontend/' ]
  [ "$(input_list triggers '["backend/", "frontend/"]')" = $'backend/\nfrontend/' ]
  [ "$(input_list triggers "'my path/'")" = 'my path/' ]
  [ -z "$(input_list triggers '')" ]
}

@test "list: bash parens fail with a multiline example" {
  run input_list triggers "('backend/' 'frontend/')"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid triggers input: ('backend/' 'frontend/')"* ]]
  [[ "$output" == *"triggers must be a multiline block (one item per line), a comma-separated line, or a JSON array."* ]]
  [[ "$output" == *"%0A  triggers: |%0A    backend/%0A    frontend/"* ]]
  [[ "$output" == *"Multiline input syntax: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepswith" ]]
}

@test "list: multiline bash parens fail" {
  run input_list triggers "$(printf "(\n'backend/'\n'frontend/'\n)")"
  [ "$status" -eq 1 ]
}

@test "list: space and semicolon separated lines fail" {
  run input_list remove_pvc 'a b'
  [ "$status" -eq 1 ]
  run input_list remove_pvc 'a;b'
  [ "$status" -eq 1 ]
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
