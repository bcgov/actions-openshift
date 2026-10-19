#!/usr/bin/env bash
# Shared input parsing for actions-openshift, same rules as bcgov/actions shared/inputs.js:
#   list:  one item per line (preferred), "a, b" on one line, or a JSON array
#          (bash "('a' 'b')" and space or semicolon separated lines fail with a before/after example)
#   bool:  true or false, any case
#   enum:  one of the listed values, any case
#   debug: the debug input, or RUNNER_DEBUG=1 (a re-run with debug logging)
# Source it, then call: input_list NAME VALUE | input_bool NAME VALUE DEFAULT |
# input_enum NAME VALUE "a b c" DEFAULT | input_debug VALUE. Errors print an annotation and return 1.

# Shared rules are explained in the bcgov/actions guide; this repo's own renames in MIGRATION.md here
INPUT_GUIDE="https://github.com/bcgov/actions/blob/main/MIGRATION.md"

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
  local name="$1" raw="$2" kind inner item
  local -a items=()
  if [[ "$raw" == \(*\) ]]; then
    kind="Bash-style parenthesized lists"
    inner="${raw:1:${#raw}-2}"
  else
    kind="Semicolon or space separated single-line lists"
    inner="$raw"
  fi
  for item in ${inner//[,;]/ }; do
    item="$(_input_strip_quotes "$item")"
    [ -n "$item" ] && items+=("$item")
  done
  [ "${#items[@]}" -gt 0 ] || items=(backend/ frontend/)
  local msg="::error title=${name}: unsupported list format::Invalid ${name} input: ${raw}"
  msg+="%0A${kind} are no longer supported."
  msg+="%0AUse a multiline block, one item per line (or a comma-separated line, or a JSON array)."
  msg+="%0ABefore:%0A  ${name}: ${raw}%0AAfter:%0A  ${name}: |"
  for item in "${items[@]}"; do msg+="%0A    ${item}"; done
  local anchor=list-inputs
  [ "$name" = "triggers" ] && anchor=triggers
  msg+="%0AMigration guide: ${INPUT_GUIDE}#${anchor}"
  echo "$msg"
}

input_list() {
  local name="$1" raw line item
  raw="$(_input_trim "${2:-}")"
  [ -n "$raw" ] || return 0
  if [[ "$raw" == \[*\] ]] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$raw"; then
    jq -r '.[] | tostring | gsub("^\\s+|\\s+$"; "") | select(. != "")' <<<"$raw"
    return 0
  fi
  if [[ "$raw" == *$'\n'* ]]; then
    while IFS= read -r line; do
      line="$(_input_strip_quotes "$(_input_trim "${line%$'\r'}")")"
      [ -n "$line" ] && printf '%s\n' "$line"
    done <<<"$raw"
    return 0
  fi
  local quoted=false
  [ "$(_input_strip_quotes "$raw")" != "$raw" ] && quoted=true
  local quotes="${raw//[^\'\"]/}"
  if [[ "$raw" == \(*\) || "$raw" == *';'* || ${#quotes} -ge 4 ]] ||
     [[ "$raw" != *,* && "$raw" =~ [[:space:]] && "$quoted" == false ]]; then
    _input_list_error "$name" "$raw"
    return 1
  fi
  if [[ "$raw" == *,* && "$quoted" == false ]]; then
    local -a parts
    IFS=',' read -r -a parts <<<"$raw"
    for item in "${parts[@]}"; do
      item="$(_input_strip_quotes "$(_input_trim "$item")")"
      if [[ "$item" =~ [[:space:]] ]]; then
        _input_list_error "$name" "$raw"
        return 1
      fi
      [ -n "$item" ] && printf '%s\n' "$item"
    done
    return 0
  fi
  printf '%s\n' "$(_input_strip_quotes "$raw")"
}

input_bool() {
  local name="$1" v
  v="$(_input_trim "${2:-}")"
  v="${v,,}"
  [ -n "$v" ] || v="${3:-false}"
  case "$v" in
    true|false) echo "$v" ;;
    *) echo "::error title=${name}: not a boolean::Invalid ${name} input: ${2:-}. Use true or false. Migration guide: ${INPUT_GUIDE}#boolean-and-enum-inputs"; return 1 ;;
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
  echo "::error title=${name}: unsupported value::Invalid ${name} input: ${2:-}. Use one of: ${allowed// /, }. Migration guide: ${INPUT_GUIDE}#boolean-and-enum-inputs"
  return 1
}

input_debug() {
  local v
  v="$(input_bool debug "${1:-}" false)" || { echo "$v"; return 1; }
  if [ "$v" = "true" ] || [ "${RUNNER_DEBUG:-}" = "1" ]; then echo true; else echo false; fi
}
