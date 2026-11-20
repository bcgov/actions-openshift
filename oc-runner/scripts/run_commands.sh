#!/bin/bash

set -eEuo pipefail
ACTION_SOURCE="bcgov/actions-openshift/oc-runner"
# Largest commands output passed on; above it the step fails rather than truncate
OUTPUT_LIMIT_BYTES=524288

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
if [ "${DEBUG:-false}" = "true" ]; then
  echo "::notice::[${ACTION_SOURCE}] Debug mode enabled for commands step (includes internal output processing)."
  set -x
  VERBOSE_ARGS=(-x)
fi

# One retry, only when the block failed on an API connect timeout (Silver drops connects from
# a runner IP for a while). Any other failure fails at once with its own exit code.
CONNECT_TIMEOUT_RE='dial tcp [^[:space:]]+: i/o timeout|Unable to connect to the server: .*timeout'
CONNECT_RETRY_DELAY="${CONNECT_RETRY_DELAY:-10}"
ATTEMPT_LOG="$(mktemp)"
trap 'rm -f "$ACTION_OUTPUT_FILE" "$COMMANDS_FILE" "$TIMEOUT_MARK" "$ATTEMPT_LOG"' EXIT

# Runs the block once and sets cmd_rc. Output is shown live and copied to ATTEMPT_LOG.
# Watchdog instead of coreutils timeout: timeout exits 124 both when it stops the block
# and when the block itself exits 124 (for example a command wrapped in its own
# `timeout`). The watchdog writes TIMEOUT_MARK before it stops the block, so only a
# block it stopped is reported as a timeout.
run_block() {
  local out_fd err_fd out_pid err_pid cmd_pid watchdog_pid
  : > "$ATTEMPT_LOG"
  exec {out_fd}> >(tee -a "$ATTEMPT_LOG")
  out_pid=$!
  exec {err_fd}> >(tee -a "$ATTEMPT_LOG" >&2)
  err_pid=$!
  bash -euo pipefail "${VERBOSE_ARGS[@]}" "$COMMANDS_FILE" 1>&"$out_fd" 2>&"$err_fd" &
  cmd_pid=$!
  (
    sleep "$COMMANDS_TIMEOUT" &
    sleep_pid=$!
    trap 'kill "$sleep_pid" 2>/dev/null; exit 0' TERM
    wait "$sleep_pid"
    touch "$TIMEOUT_MARK"
    kill -TERM "$cmd_pid" 2>/dev/null
  ) >/dev/null 2>&1 {out_fd}>&- {err_fd}>&- &
  watchdog_pid=$!

  cmd_rc=0
  wait "$cmd_pid" || cmd_rc=$?
  kill -TERM "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  exec {out_fd}>&- {err_fd}>&-
  # A failed block's log is read for the retry check, so give tee up to 5 s to finish copying
  # it. A background child left by the block can hold the output open, so the wait is bounded
  # and the copies are then stopped. Not after success or the timeout input.
  if [ "$cmd_rc" -ne 0 ] && [ ! -e "$TIMEOUT_MARK" ]; then
    local _
    for _ in $(seq 50); do
      kill -0 "$out_pid" 2>/dev/null || kill -0 "$err_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill "$out_pid" "$err_pid" 2>/dev/null || true
  fi
}

attempt=1
while :; do
  run_block
  if [ -e "$TIMEOUT_MARK" ]; then
    echo "::error title=${ACTION_SOURCE}: commands timed out::[${ACTION_SOURCE}] commands exceeded timeout ${COMMANDS_TIMEOUT}."
    exit 124
  fi
  if [ "$cmd_rc" -ne 0 ] && [ "$attempt" -eq 1 ] && grep -Eq "$CONNECT_TIMEOUT_RE" "$ATTEMPT_LOG"; then
    echo "::warning title=${ACTION_SOURCE}: retrying commands::[${ACTION_SOURCE}] commands block failed (exit code ${cmd_rc}) on an OpenShift API connect timeout; running the whole block once more in ${CONNECT_RETRY_DELAY}s."
    # Outputs from the failed attempt are dropped; the retry writes its own
    : > "$ACTION_OUTPUT_FILE"
    sleep "$CONNECT_RETRY_DELAY"
    attempt=2
    continue
  fi
  break
done

if [ "$cmd_rc" -ne 0 ]; then
  if [ "$cmd_rc" -eq 124 ]; then
    echo "::error::[${ACTION_SOURCE}] Exit code 124 came from a command inside the commands block (for example its own 'timeout'), not from the ${COMMANDS_TIMEOUT} timeout input."
  fi
  on_commands_error "$cmd_rc"
fi

# Map user-written output lines to the action's generic commands output.
# Allows plain `echo "value" >> "$GITHUB_OUTPUT"` without requiring `commands=`.
if [ -s "$ACTION_OUTPUT_FILE" ]; then
  MAPPED_FILE="$(mktemp)"
  trap 'rm -f "$ACTION_OUTPUT_FILE" "$COMMANDS_FILE" "$TIMEOUT_MARK" "$ATTEMPT_LOG" "$MAPPED_FILE"' EXIT
  {
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
  } > "$MAPPED_FILE"

  # GitHub allows 1 MB of outputs per job, counted as UTF-16 (2 bytes per character)
  MAPPED_BYTES="$(wc -c < "$MAPPED_FILE")"
  if [ "$MAPPED_BYTES" -gt "$OUTPUT_LIMIT_BYTES" ]; then
    echo "::error title=${ACTION_SOURCE}: commands output too large::[${ACTION_SOURCE}] commands output is ${MAPPED_BYTES} bytes; the limit is ${OUTPUT_LIMIT_BYTES} bytes. Write large data to a file or artifact and put only a path or summary in \$GITHUB_OUTPUT."
    exit 1
  fi

  DELIM="EOF_ACTION_OC_RUNNER_COMMANDS_$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "${RANDOM}${RANDOM}$$")"
  {
    echo "commands<<$DELIM"
    cat "$MAPPED_FILE"
    echo "$DELIM"
  } >> "$REAL_GITHUB_OUTPUT"
fi

if [ "${DEBUG:-false}" = "true" ]; then
  set +x
fi
