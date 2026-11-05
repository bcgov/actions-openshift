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
unknown_json=$'{\n  "commands": "oc version",\n  "not_an_input": "a\\nb: c"\n}'

check 'declared inputs pass' 'assert_known_inputs oc-runner "$ok_json" >/dev/null'
check 'empty inputs pass' 'assert_known_inputs oc-runner "{}" >/dev/null'
out=$(assert_known_inputs oc-runner "$unknown_json"); rc=$?
check 'unknown input fails' '[[ $rc -eq 1 ]]'
check 'error annotation' '[[ "$out" == "::error title=oc-runner: unknown input::"* ]]'
check 'names key' '[[ "$out" == *"not_an_input: not an input of oc-runner"* ]]'
check 'links check docs' '[[ "$out" == *"bcgov/actions/blob/main/shared/README.md#unknown-inputs"* ]]'
check 'no rename text' '[[ "$out" != *renamed* ]]'
check 'spaced key is not its underscore form' '! assert_known_inputs oc-runner $'"'"'{\n  "oc version": "x"\n}'"'"' >/dev/null'
check 'value text is not read as a key' '[[ "$out" != *" b: "* ]]'
for f in */action.yml; do
  check "${f%/action.yml}: parses inputs" '[[ -n "$(_declared_inputs "$f")" ]] || ! grep -q "^inputs:" "$f"'
done
exit $fail
