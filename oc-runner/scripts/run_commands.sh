#!/bin/bash

set -eEuo pipefail
ACTION_SOURCE="bcgov/actions-openshift/oc-runner"

on_commands_error() {
  exit_code="${1:-$?}"
  set +x
  echo "::error title=${ACTION_SOURCE}: commands input failed::[${ACTION_SOURCE}] commands block failed with exit code ${exit_code}."
  echo "::error::[${ACTION_SOURCE}] If optional grep/pipeline failures are expected, guard them with '|| true' or explicit condition checks."
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### ${ACTION_SOURCE} failure"
      echo
      echo "- Component: commands input"
      echo "- Exit code: ${exit_code}"
      echo "- Hint: if optional grep/pipeline failures are expected, guard with \`|| true\` or explicit condition checks"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit "$exit_code"
}

REAL_GITHUB_OUTPUT="$GITHUB_OUTPUT"
ACTION_OUTPUT_FILE="$(mktemp)"
COMMANDS_FILE="$(mktemp)"
TIMEOUT_MARK="${COMMANDS_FILE}.timed-out"
export GITHUB_OUTPUT="$ACTION_OUTPUT_FILE"
trap 'rm -f "$ACTION_OUTPUT_FILE" "$COMMANDS_FILE" "$TIMEOUT_MARK"' EXIT

if ! [[ "$COMMANDS_TIMEOUT" =~ ^[0-9]+[mhs]$ ]]; then
  echo "::error::Invalid timeout: '${COMMANDS_TIMEOUT}'. Use e.g. 10m, 30s, 1h."
  exit 1
fi

printf '%s\n' "$COMMANDS" > "$COMMANDS_FILE"

VERBOSE_ARGS=()
if [ "$ENABLE_VERBOSE" = "true" ]; then
  echo "::notice::[${ACTION_SOURCE}] Verbose mode enabled for commands step (includes internal output processing)."
  set -x
  VERBOSE_ARGS=(-x)
fi

# Watchdog instead of coreutils timeout: timeout exits 124 both when it stops the block
# and when the block itself exits 124 (for example a command wrapped in its own
# `timeout`). The watchdog writes TIMEOUT_MARK before it stops the block, so only a
# block it stopped is reported as a timeout.
bash -euo pipefail "${VERBOSE_ARGS[@]}" "$COMMANDS_FILE" &
cmd_pid=$!
(
  sleep "$COMMANDS_TIMEOUT" &
  sleep_pid=$!
  trap 'kill "$sleep_pid" 2>/dev/null; exit 0' TERM
  wait "$sleep_pid"
  touch "$TIMEOUT_MARK"
  kill -TERM "$cmd_pid" 2>/dev/null
) >/dev/null 2>&1 &
watchdog_pid=$!

cmd_rc=0
wait "$cmd_pid" || cmd_rc=$?
kill -TERM "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true

if [ -e "$TIMEOUT_MARK" ]; then
  echo "::error title=${ACTION_SOURCE}: commands timed out::[${ACTION_SOURCE}] commands exceeded timeout ${COMMANDS_TIMEOUT}."
  exit 124
fi
if [ "$cmd_rc" -ne 0 ]; then
  if [ "$cmd_rc" -eq 124 ]; then
    echo "::error::[${ACTION_SOURCE}] Exit code 124 came from a command inside the commands block (for example its own 'timeout'), not from the ${COMMANDS_TIMEOUT} timeout input."
  fi
  on_commands_error "$cmd_rc"
fi

# Map user-written output lines to the action's generic commands output.
# Allows plain `echo "value" >> "$GITHUB_OUTPUT"` without requiring `commands=`.
if [ -s "$ACTION_OUTPUT_FILE" ]; then
  DELIM="EOF_ACTION_OC_RUNNER_COMMANDS_$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "${RANDOM}${RANDOM}$$")"
  {
    echo "commands<<$DELIM"
    if grep -q '^commands=' "$ACTION_OUTPUT_FILE"; then
      sed -n 's/^commands=//p' "$ACTION_OUTPUT_FILE"
    elif grep -q '^commands<<' "$ACTION_OUTPUT_FILE"; then
      awk '
        /^commands<</ {
          split($0, a, "<<")
          tag = a[2]
          in_block = 1
          next
        }
        in_block && $0 == tag {
          in_block = 0
          exit
        }
        in_block {
          print
        }
      ' "$ACTION_OUTPUT_FILE"
    else
      cat "$ACTION_OUTPUT_FILE"
    fi
    echo "$DELIM"
  } >> "$REAL_GITHUB_OUTPUT"
fi

if [ "$ENABLE_VERBOSE" = "true" ]; then
  set +x
fi
