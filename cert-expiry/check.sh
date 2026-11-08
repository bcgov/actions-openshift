#!/bin/bash
# Read-only TLS expiry check. Reads each host's public leaf certificate with
# openssl s_client and prints only the host, expiry date and days left.
# Nothing here reads or prints private keys; the server never sends one.
set -euo pipefail

HOSTS="${INPUT_HOSTS:-}"
DIVISOR="${INPUT_LIFETIME_DIVISOR-3}"
MARGIN="${INPUT_MARGIN_DAYS-0}"
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

in_range "$DIVISOR" 2 100 \
  || fail "lifetime_divisor must be a whole number from 2 to 100, got '${DIVISOR}'." "Set lifetime_divisor to 3 to report a certificate when a third of its lifetime is left."
DIVISOR=$((10#$DIVISOR))
in_range "$MARGIN" 0 3650 \
  || fail "margin_days must be a whole number from 0 to 3650, got '${MARGIN}'." "Set margin_days to a number of days, for example margin_days: 3."
MARGIN=$((10#$MARGIN))
in_range "$TIMEOUT" 1 120 \
  || fail "timeout must be a whole number from 1 to 120, got '${TIMEOUT}'." "Set timeout to a number of seconds, for example timeout: 10."
TIMEOUT=$((10#$TIMEOUT))
case "$FAIL_ON_FINDINGS" in
  true | false) ;;
  *) fail "fail_on_findings must be true or false, got '${FAIL_ON_FINDINGS}'." "Set fail_on_findings: true or fail_on_findings: false." ;;
esac

# Shared list rules (shared/inputs.sh): one host per line, or a single host.
# '# comments' are dropped first.
# shellcheck source=../shared/inputs.sh
source "$(dirname "${BASH_SOURCE[0]}")/../shared/inputs.sh"
COMMENTLESS=""
while IFS= read -r line; do
  COMMENTLESS+="${line%%#*}"$'\n'
done <<< "$HOSTS"
LIST="$(input_list hosts "$COMMENTLESS")" || { echo "$LIST"; exit 1; }

# Validate and de-duplicate
LABEL='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
ENTRIES=()
declare -A SEEN=()
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  {
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
  }
done <<< "$LIST"

((${#ENTRIES[@]} > 0)) || fail "No hostnames to check." "Set hosts to one or more hostnames, one per line."

NOW=$(date -u +%s)
FINDINGS='[]'
{
  echo "## TLS certificate expiry"
  echo ""
  echo "Reporting a certificate when 1/${DIVISOR} of its lifetime is left, minus ${MARGIN} days."
  echo ""
  echo "| Host | Status | Expires (UTC) | Days left | Lifetime (days) |"
  echo "|---|---|---|---|---|"
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
    not_before=""
    not_after=""
    days_left=""
    lifetime_days=""
  else
    not_before=$(openssl x509 -noout -startdate <<< "$CERT" | cut -d= -f2-)
    not_after=$(openssl x509 -noout -enddate <<< "$CERT" | cut -d= -f2-)
    start=$(date -u -d "$not_before" +%s)
    end=$(date -u -d "$not_after" +%s)
    days_left=$(((end - NOW) / 86400))
    lifetime_days=$(((end - start) / 86400))
    not_before=$(date -u -d "@${start}" +%Y-%m-%dT%H:%M:%SZ)
    not_after=$(date -u -d "@${end}" +%Y-%m-%dT%H:%M:%SZ)
    # Due when a 1/DIVISOR share of this certificate's own lifetime is left, less the margin
    limit=$(((end - start) / DIVISOR - MARGIN * 86400))
    ((limit >= 0)) || limit=0
    # A host with no certificate of its own is served the router default, which does not cover it
    covers=$(openssl x509 -noout -checkhost "$host" <<< "$CERT" 2> /dev/null || true)
    if [[ "$covers" != *"does match"* ]]; then
      status=uncovered
    elif ((end <= NOW)); then
      status=expired
    elif ((end - NOW <= limit)); then
      status=expiring
    else
      status=ok
    fi
  fi

  case "$status" in
    ok) echo "OK: ${label} expires ${not_after} (${days_left} days left)" ;;
    expiring) echo "::warning::${label} certificate expires ${not_after} (${days_left} days left of a ${lifetime_days} day certificate)" ;;
    uncovered) echo "::warning::${label} serves a certificate that does not cover it (another name, or the router default)" ;;
    expired) echo "::warning::${label} certificate expired ${not_after}" ;;
    unreadable) echo "::warning::${label}: could not read a certificate (no TLS answer within ${TIMEOUT}s, DNS failure or handshake error)" ;;
  esac
  echo "| ${label} | ${status} | ${not_after:--} | ${days_left:--} | ${lifetime_days:--} |" >> "$SUMMARY"

  if [[ "$status" != ok ]]; then
    FINDINGS=$(jq -c --arg h "$label" --arg s "$status" --arg b "$not_before" --arg n "$not_after" --arg d "$days_left" --arg l "$lifetime_days" \
      '. + [{host: $h, status: $s, not_before: $b, not_after: $n, days_left: $d, lifetime_days: $l}]' <<< "$FINDINGS")
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
  echo "::error::${COUNT} host(s) need attention: certificate not covering the host, due for renewal, expired, or unreadable."
  echo "Fix: renew and install the certificate (see cert-keeper), or remove the host from the list if it is retired."
  exit 1
fi
