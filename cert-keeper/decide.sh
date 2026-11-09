#!/usr/bin/env bash
# Decides whether a host needs a new certificate, from the findings of check.sh.
# Due when the served certificate does not cover the host, has expired, or has a
# third of its own lifetime or less left; or when force is set. An unreadable
# host is an error: nothing can be issued until DNS and the router answer.
set -euo pipefail

FINDINGS="${FINDINGS:-[]}"
FORCE="${FORCE:-false}"
HOST="${HOST:-}"
OUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

die() {
  echo "::error title=cert-keeper::$1"
  echo "Fix: $2"
  exit 1
}

[ -n "$HOST" ] || die "HOST is required." "Pass the hostname to check."
jq -e 'type == "array"' <<< "$FINDINGS" > /dev/null 2>&1 || die "findings is not a JSON array." "Pass the findings output of the check step."

# check.sh reports hosts in lowercase and only lists those needing attention
row="$(jq -c --arg h "${HOST,,}" '[.[] | select(.host == $h)][0] // {}' <<< "$FINDINGS")"
status="$(jq -r '.status // "ok"' <<< "$row")"
days_left="$(jq -r '.days_left // ""' <<< "$row")"
lifetime="$(jq -r '.lifetime_days // ""' <<< "$row")"

case "$status" in
  unreadable)
    die "Could not read a certificate for ${HOST} over TLS." "Check ${HOST} resolves to the OpenShift router and answers on port 443, then run again." ;;
  uncovered)
    due=true
    reason="the certificate served for ${HOST} does not cover it" ;;
  expired)
    due=true
    reason="the certificate for ${HOST} has expired" ;;
  expiring)
    due=true
    reason="${days_left} of ${lifetime} days are left, a third of the lifetime or less" ;;
  ok)
    if [ "$FORCE" = true ]; then
      due=true
      reason="force is set"
    else
      due=false
      reason="the certificate for ${HOST} is not due for renewal"
    fi ;;
  *)
    die "Unexpected status '${status}' for ${HOST}." "Use a check.sh that reports uncovered, expiring, expired and unreadable." ;;
esac

echo "due=${due}" >> "$OUT"
echo "reason=${reason}" >> "$OUT"
echo "cert-keeper: ${HOST} due=${due}: ${reason}"
printf '%s\n' "### cert-keeper" "" "- ${HOST}: due=${due} (${reason})" >> "$SUMMARY"
