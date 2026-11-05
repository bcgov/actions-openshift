#!/usr/bin/env bash
# Fail on inputs an action does not declare. Copy of bcgov/actions
# shared/inputs.js `assert-known`; bcgov/actions is the source of truth:
#   https://github.com/bcgov/actions/blob/main/shared/README.md#unknown-inputs
#
# GitHub only warns ("Unexpected input(s)") on a `with:` key an action does
# not declare and keeps going. Composite actions run this as their first step:
#   env:
#     INPUTS_JSON: ${{ toJSON(inputs) }}   # holds undeclared keys too
#   run: bash "$GITHUB_ACTION_PATH/../shared/assert-known.sh" "$GITHUB_ACTION_PATH"
# Keys compare case-insensitively as written; nothing per action beyond action.yml.

INPUTS_DOCS='https://github.com/bcgov/actions/blob/main/shared/README.md#unknown-inputs'

# Declared input names from action.yml (top-level `inputs:` block).
_declared_inputs() {
  awk '
    /^inputs:[[:space:]]*(#.*)?$/ { f = 1; next }
    f && /^[^[:space:]#]/ { exit }
    f && match($0, /^[[:space:]]+/) {
      if (!ind) ind = RLENGTH
      if (RLENGTH != ind) next
      line = substr($0, RLENGTH + 1)
      if (line ~ /^#/ || line !~ /:/) next
      sub(/:.*/, "", line); gsub(/^["'\'']|["'\'']$/, "", line)
      print line
    }' "$1"
}

# Top-level keys of `toJSON(inputs)` (GitHub pretty-prints, two-space indent).
_given_inputs() {
  printf '%s\n' "$1" | sed -n 's/^  "\(\([^"\\]\|\\.\)*\)": .*/\1/p'
}

# assert_known_inputs ACTION_DIR [INPUTS_JSON]
assert_known_inputs() {
  local dir="$1" json="${2-${INPUTS_JSON-}}" action yml key k found msg
  action=$(basename "$(cd "$dir" && pwd)")
  yml="$dir/action.yml"; [[ -f "$yml" ]] || yml="$dir/action.yaml"
  [[ -f "$yml" ]] || { echo "::error::no action.yml in $dir"; return 1; }
  local -a declared=() unknown=()
  mapfile -t declared < <(_declared_inputs "$yml")
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    found=
    for k in "${declared[@]}"; do [[ "${k,,}" == "${key,,}" ]] && found=1 && break; done
    [[ -n "$found" ]] || unknown+=("$key")
  done < <(_given_inputs "$json")
  [[ ${#unknown[@]} -eq 0 ]] && return 0

  msg="::error title=${action}: unknown input::Unknown input(s) for ${action}: $(IFS=,; echo "${unknown[*]}" | sed 's/,/, /g')"
  for key in "${unknown[@]}"; do msg+="%0A  ${key}: not an input of ${action}"; done
  msg+="%0AInputs: $(IFS=,; echo "${declared[*]}" | sed 's/,/, /g')"
  msg+="%0ADocs: https://github.com/bcgov/actions-openshift/blob/main/${action}/README.md"
  msg+="%0ACheck: ${INPUTS_DOCS}"
  echo "$msg"
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  assert_known_inputs "$1"
fi
