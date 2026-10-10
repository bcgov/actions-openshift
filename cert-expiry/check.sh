#!/bin/bash
# Read-only TLS expiry check. Reads each host's public leaf certificate with
# openssl s_client and prints only the host, expiry date and days left.
# Nothing here reads or prints private keys; the server never sends one.
set -euo pipefail

HOSTS="${INPUT_HOSTS:-}"
DAYS="${INPUT_DAYS-30}"
TIMEOUT="${INPUT_TIMEOUT-10}"
FAIL_ON_FINDINGS="${INPUT_FAIL_ON_FINDINGS-true}"
OUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

fail() {
  echo "::error::$1"
  echo "Fix: $2"
  exit 1
}

# True when $1 is a whole number from $2 to $3 (at most 5 digits, no overflow)
in_range() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
  ((10#$1 >= $2 && 10#$1 <= $3))
}

for tool in openssl jq timeout; do
  command -v "$tool" > /dev/null || fail "$tool is not installed on this runner." "Use an ubuntu runner, or install $tool before this step."
done

in_range "$DAYS" 1 3650 \
  || fail "days must be a whole number from 1 to 3650, got '${DAYS}'." "Set days to a number of days, for example days: 30."
DAYS=$((10#$DAYS))
in_range "$TIMEOUT" 1 120 \
  || fail "timeout must be a whole number from 1 to 120, got '${TIMEOUT}'." "Set timeout to a number of seconds, for example timeout: 10."
TIMEOUT=$((10#$TIMEOUT))
case "$FAIL_ON_FINDINGS" in
  true | false) ;;
  *) fail "fail_on_findings must be true or false, got '${FAIL_ON_FINDINGS}'." "Set fail_on_findings: true or fail_on_findings: false." ;;
esac

LIST="$HOSTS"

# Parse: drop comments, split on commas and whitespace, validate, de-duplicate
LABEL='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
ENTRIES=()
declare -A SEEN=()
while IFS= read -r line; do
  line="${line%%#*}"
  # read -a splits without pathname expansion, so '*' is rejected, not globbed
  IFS=$' \t,' read -r -a parts <<< "$line"
  for entry in "${parts[@]}"; do
    if [[ "$entry" == *"://"* || "$entry" == */* ]]; then
      fail "'${entry}' is a URL, not a hostname." "List the hostname only, for example myapp.gov.bc.ca or myapp.gov.bc.ca:8443."
    fi
    host="${entry%%:*}"
    port=443
    [[ "$entry" == *:* ]] && port="${entry#*:}"
    [[ "$host" =~ ^${LABEL}(\.${LABEL})*$ ]] \
      || fail "'${entry}' is not a valid hostname." "Use letters, digits, dots and hyphens, for example myapp.gov.bc.ca."
    in_range "$port" 1 65535 \
      || fail "'${entry}' has an invalid port." "Use host:port with a port from 1 to 65535, or leave the port off for 443."
    key="${host,,}:$((10#$port))"
    [[ -n "${SEEN[$key]:-}" ]] && continue
    SEEN[$key]=1
    ENTRIES+=("$key")
  done
done <<< "$LIST"

((${#ENTRIES[@]} > 0)) || fail "No hostnames to check." "Set hosts to one or more hostnames, one per line."

NOW=$(date -u +%s)
WINDOW=$((DAYS * 86400))
FINDINGS='[]'
{
  echo "## TLS certificate expiry"
  echo ""
  echo "Warning window: ${DAYS} days."
  echo ""
  echo "| Host | Status | Expires (UTC) | Days left |"
  echo "|---|---|---|---|"
} >> "$SUMMARY"

for key in "${ENTRIES[@]}"; do
  host="${key%:*}"
  port="${key##*:}"
  label="$host"
  [[ "$port" == 443 ]] || label="$key"

  # Leaf certificate (public) only; stdin closed so the handshake ends at once
  CERT=$(timeout "$TIMEOUT" openssl s_client -connect "${host}:${port}" -servername "$host" < /dev/null 2> /dev/null \
    | openssl x509 2> /dev/null) || CERT=""

  if [[ -z "$CERT" ]]; then
    status=unreadable
    not_after=""
    days_left=""
  else
    not_after=$(openssl x509 -noout -enddate <<< "$CERT" | cut -d= -f2-)
    end=$(date -u -d "$not_after" +%s)
    days_left=$(((end - NOW) / 86400))
    not_after=$(date -u -d "@${end}" +%Y-%m-%dT%H:%M:%SZ)
    if ((end <= NOW)); then
      status=expired
    elif ((end - NOW <= WINDOW)); then
      status=expiring
    else
      status=ok
    fi
  fi

  case "$status" in
    ok) echo "OK: ${label} expires ${not_after} (${days_left} days left)" ;;
    expiring) echo "::warning::${label} certificate expires ${not_after} (${days_left} days left, within ${DAYS})" ;;
    expired) echo "::warning::${label} certificate expired ${not_after}" ;;
    unreadable) echo "::warning::${label}: could not read a certificate (no TLS answer within ${TIMEOUT}s, DNS failure or handshake error)" ;;
  esac
  echo "| ${label} | ${status} | ${not_after:--} | ${days_left:--} |" >> "$SUMMARY"

  if [[ "$status" != ok ]]; then
    FINDINGS=$(jq -c --arg h "$label" --arg s "$status" --arg n "$not_after" --arg d "$days_left" \
      '. + [{host: $h, status: $s, not_after: $n, days_left: $d}]' <<< "$FINDINGS")
  fi
done

COUNT=$(jq length <<< "$FINDINGS")
{
  echo "findings=${FINDINGS}"
  echo "checked=${#ENTRIES[@]}"
} >> "$OUT"
echo "" >> "$SUMMARY"
echo "Checked ${#ENTRIES[@]} host(s); ${COUNT} need attention."

if ((COUNT > 0)) && [[ "$FAIL_ON_FINDINGS" == true ]]; then
  echo "::error::${COUNT} host(s) need attention: certificate expiring within ${DAYS} days, expired, or unreadable."
  echo "Fix: renew and install the certificate (see route-tls), or remove the host from the list if it is retired."
  exit 1
fi
