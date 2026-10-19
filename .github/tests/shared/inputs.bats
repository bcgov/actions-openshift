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

@test "list: bash parens fail with a before/after example" {
  run input_list triggers "('backend/' 'frontend/')"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid triggers input: ('backend/' 'frontend/')"* ]]
  [[ "$output" == *"Bash-style parenthesized lists are no longer supported"* ]]
  [[ "$output" == *"%0A  triggers: |%0A    backend/%0A    frontend/"* ]]
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
  [ "$(input_debug '')" = false ]
  [ "$(RUNNER_DEBUG=1 input_debug '')" = true ]
}

@test "errors link the migration guide" {
  run input_list triggers "('a/' 'b/')"
  [[ "$output" == *"Migration guide: https://github.com/bcgov/actions/blob/main/MIGRATION.md#triggers"* ]]
  run input_list remove_pvc 'a b'
  [[ "$output" == *"MIGRATION.md#list-inputs"* ]]
  run input_bool dry_run yes false
  [[ "$output" == *"MIGRATION.md#boolean-and-enum-inputs"* ]]
  run input_enum cleanup x 'helm label' label
  [[ "$output" == *"MIGRATION.md#boolean-and-enum-inputs"* ]]
}
