#!/usr/bin/env bash
# Shared input parsing for actions-openshift, same rules as bcgov/actions shared/inputs.js:
#   list:  one item per line, or a single value
#          (anything else, e.g. "a, b", a JSON array or "a b", fails with a multiline example)
#   bool:  true or false, any case
#   enum:  one of the listed values, any case
#   debug: the debug input, or RUNNER_DEBUG=1 (a re-run with debug logging)
# Source it, then call: input_list NAME VALUE | input_bool NAME VALUE DEFAULT |
# input_enum NAME VALUE "a b c" DEFAULT | input_debug VALUE. Errors print an annotation and return 1.

_input_strip_quotes() {
  local s="$1"
  if [[ ${#s} -ge 2 && ( ( "$s" == \'*\' ) || ( "$s" == \"*\" ) ) ]]; then
    s="${s:1:${#s}-2}"
  fi
  printf '%s' "$s"
}

_input_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

_input_list_error() {
  local name="$1" raw="$2" inner="$2" item
  local -a items=()
  [[ "$raw" == \(*\) || "$raw" == \[*\] ]] && inner="${raw:1:${#raw}-2}"
  # Tokens: '...' or "..." (spaces kept), else runs without spaces, commas or semicolons
  local re="^[[:space:],;]*('[^']*'|\"[^\"]*\"|[^[:space:],;]+)(.*)$"
  while [[ "$inner" =~ $re ]]; do
    item="$(_input_strip_quotes "${BASH_REMATCH[1]}")"
    inner="${BASH_REMATCH[2]}"
    [ -n "$item" ] && items+=("$item")
  done
  [ "${#items[@]}" -gt 0 ] || items=(backend/ frontend/)
  local msg="::error title=${name}: list format::Invalid ${name} input: ${raw}"
  msg+="%0A${name} takes one item per line, or a single value."
  msg+="%0AGot:%0A  ${name}: ${raw}%0AUse:%0A  ${name}: |"
  # Items with spaces keep their quotes, so the suggested block parses
  for item in "${items[@]}"; do
    if [[ "$item" =~ [[:space:]] ]]; then msg+="%0A    \"${item}\""; else msg+="%0A    ${item}"; fi
  done
  # GitHub's docs on step inputs (with:), including multiline values
  msg+="%0AMultiline input syntax: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepswith"
  echo "$msg"
}

# True when $1 has a comma outside {...}, so globs like src/{a,b}/** are one item
_input_has_list_comma() {
  local s="$1" ch depth=0 i
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    case "$ch" in
      '{') depth=$((depth + 1)) ;;
      '}') [ "$depth" -gt 0 ] && depth=$((depth - 1)) ;;
      ',') [ "$depth" -eq 0 ] && return 0 ;;
    esac
  done
  return 1
}

# One item per line, or a single value. Blank lines are ignored and one layer
# of quotes around each item is removed. An item holding a list of its own
# (commas outside {...}, semicolons, spaces outside quotes, brackets) fails.
input_list() {
  local name="$1" raw line item
  local -a items=()
  raw="$(_input_trim "${2:-}")"
  [ -n "$raw" ] || return 0
  if [[ "$raw" =~ ^[\(\[] && "$raw" =~ [\)\]]$ ]]; then
    _input_list_error "$name" "$raw"
    return 1
  fi
  while IFS= read -r line; do
    line="$(_input_trim "${line%$'\r'}")"
    [ -n "$line" ] || continue
    if ! [[ "$line" =~ ^\'[^\']*\'$ || "$line" =~ ^\"[^\"]*\"$ ]]; then
      if [[ "$line" =~ [[:space:]\;\'\"] || "$line" =~ ^[\(\[] || "$line" =~ [\)\]]$ ]] || _input_has_list_comma "$line"; then
        _input_list_error "$name" "$raw"
        return 1
      fi
    fi
    item="$(_input_strip_quotes "$line")"
    [ -n "$item" ] && items+=("$item")
  done <<<"$raw"
  [ "${#items[@]}" -eq 0 ] || printf '%s\n' "${items[@]}"
}

input_bool() {
  local name="$1" v
  v="$(_input_trim "${2:-}")"
  v="${v,,}"
  [ -n "$v" ] || v="${3:-false}"
  case "$v" in
    true|false) echo "$v" ;;
    *) echo "::error title=${name}: not a boolean::Invalid ${name} input: ${2:-}. Use true or false."; return 1 ;;
  esac
}

input_enum() {
  local name="$1" v allowed="$3" a
  v="$(_input_trim "${2:-}")"
  v="${v,,}"
  [ -n "$v" ] || v="$4"
  for a in $allowed; do
    [ "$v" = "$a" ] && { echo "$v"; return 0; }
  done
  echo "::error title=${name}: unsupported value::Invalid ${name} input: ${2:-}. Use one of: ${allowed// /, }."
  return 1
}

input_debug() {
  local v
  v="$(input_bool debug "${1:-}" false)" || { echo "$v"; return 1; }
  if [ "$v" = "true" ] || [ "${RUNNER_DEBUG:-}" = "1" ]; then echo true; else echo false; fi
}
