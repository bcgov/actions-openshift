#!/usr/bin/env bash
# Tests for shared/assert-known.sh: bash shared/assert-known.test.sh
# Variables are read inside check() via eval.
# shellcheck disable=SC2034
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=assert-known.sh
source shared/assert-known.sh
fail=0
check() { if eval "$2"; then echo "ok - $1"; else echo "not ok - $1"; fail=1; fi; }

ok_json=$'{\n  "commands": "oc version",\n  "debug": "false"\n}'
renamed_json=$'{\n  "commands": "oc version",\n  "verbose": "true",\n  "diff_branch": "main"\n}'
unknown_json=$'{\n  "commands": "oc version",\n  "not_an_input": "a\\nb: c"\n}'

check 'declared inputs pass' 'assert_known_inputs oc-runner "$ok_json" >/dev/null'
check 'empty inputs pass' 'assert_known_inputs oc-runner "{}" >/dev/null'
out=$(assert_known_inputs oc-runner "$renamed_json"); rc=$?
check 'renamed input fails' '[[ $rc -eq 1 ]]'
check 'error annotation' '[[ "$out" == "::error title=oc-runner: unknown input::"* ]]'
check 'names replacement' '[[ "$out" == *"verbose: renamed to debug"* && "$out" == *"diff_branch: renamed to base"* ]]'
check 'links inputs reference' '[[ "$out" == *"bcgov/actions/blob/main/docs/INPUTS.md"* ]]'
out=$(assert_known_inputs oc-runner "$unknown_json"); rc=$?
check 'unknown input fails and names key' '[[ $rc -eq 1 && "$out" == *"not_an_input: not an input of oc-runner"* ]]'
check 'value text is not read as a key' '[[ "$out" != *" b: "* ]]'
out=$(assert_known_inputs deployer $'{\n  "login_attempts": "3"\n}')
check 'removed input says removed' '[[ "$out" == *"login_attempts: removed"* ]]'
for a in crunchy deployer oc-runner; do
  for kv in $(_renamed "$a"); do
    new="${kv#*=}"; old="${kv%%=*}"
    check "$a: $old not declared" '! _declared_inputs "$a/action.yml" | grep -qx "$old"'
    [[ -n "$new" ]] && check "$a: $new declared" '_declared_inputs "$a/action.yml" | grep -qx "$new"'
  done
done
for f in */action.yml; do
  check "${f%/action.yml}: parses inputs" '[[ -n "$(_declared_inputs "$f")" ]] || ! grep -q "^inputs:" "$f"'
done
exit $fail
