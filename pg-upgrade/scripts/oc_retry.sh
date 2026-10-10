#!/usr/bin/env bash
# GitHub runners sometimes can't reach the OpenShift API for a few seconds (bcgov/actions-openshift#49).
# Retry a call only when the connection was never made (dial errors), so no request reached the
# server and even a create, patch or exec is safe to repeat. stdin is kept for "-f -" and "exec -i";
# output is printed once. Sourced by run.sh and by this repo's cluster tests.
OC_RETRIES="${OC_RETRIES:-6}"
OC_RETRY_DELAY="${OC_RETRY_DELAY:-10}"
oc() {
  local in out err try=1 rc
  in="$(mktemp)" out="$(mktemp)" err="$(mktemp)"
  if [[ " $* " == *" -f - "* || " $* " == *" -i "* ]]; then cat > "$in"; else : > "$in"; fi
  while :; do
    rc=0
    command oc "$@" < "$in" > "$out" 2> "$err" || rc=$?
    if [ "$rc" = 0 ] || [ "$try" -ge "$OC_RETRIES" ] || ! grep -qE 'dial tcp|connection refused|no route to host' "$err"; then break; fi
    echo "OpenShift API unreachable (attempt ${try}/${OC_RETRIES}), retrying in ${OC_RETRY_DELAY}s..." >&2
    try=$((try + 1))
    sleep "$OC_RETRY_DELAY"
  done
  cat "$out"
  cat "$err" >&2
  rm -f "$in" "$out" "$err"
  return "$rc"
}
