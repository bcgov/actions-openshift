#!/usr/bin/env bash
# OpenShift Route TLS. GitHub Action wrapper: action.yml.
# Run this file locally with the same env vars.
set -euo pipefail

DRY_RUN="${DRY_RUN:-false}"
TLS_CA_CERTIFICATE="${TLS_CA_CERTIFICATE:-}"
OC_NAMESPACE="${OC_NAMESPACE:-}"
OC_SERVER="${OC_SERVER:-}"
OC_TOKEN="${OC_TOKEN:-}"

err() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error::$*"
  else
    echo "error: $*" >&2
  fi
}

summarize() {
  echo "::notice title=Route TLS::$1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "### Route TLS" "" "- $1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

die() {
  err "$1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "### Route TLS" "" "- dry_run=${DRY_RUN}. Failed: $1" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
}

# set -e exits before die on oc login, backup, and oc apply. Report the line and
# status only. BASH_COMMAND can contain the token or the private key.
trap 'rc=$?; line=${LINENO}; trap - ERR; die "Command failed at line ${line} (exit status ${rc}). See the step log for details."' ERR

load_file() {
  # $1 = destination var, $2 = optional *_FILE path. File wins when set.
  local dest="$1" file_var="$2"
  local file="${!file_var:-}"
  if [ -n "$file" ]; then
    [ -f "$file" ] || die "PEM file not found: $file"
    local value
    value="$(cat "$file")"
    printf -v "$dest" '%s' "$value"
  fi
}

host_matches_name() {
  local host name suffix
  host="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  name="$(printf '%s' "$2" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [ "$name" = "$host" ] && return 0
  if [ "${name#\*.}" != "$name" ]; then
    suffix="${name#\*}"
    [ "${host%"$suffix"}" != "$host" ] && [ "${host#*.}" = "${name#\*.}" ] && return 0
  fi
  return 1
}

cert_covers_host() {
  local pem="$1" host="$2" name cn
  local sans
  sans="$(openssl x509 -in "$pem" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed -n 's/.*DNS:[[:space:]]*\([^[:space:]]*\).*/\1/p')"
  if [ -n "$sans" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] && host_matches_name "$host" "$name" && return 0
    done <<< "$sans"
    return 1
  fi
  cn="$(openssl x509 -in "$pem" -noout -subject -nameopt RFC2253 2>/dev/null | sed -n 's/.*CN=\([^,]*\).*/\1/p')"
  [ -n "$cn" ] && host_matches_name "$host" "$cn"
}

load_file TLS_CERTIFICATE TLS_CERTIFICATE_FILE
load_file TLS_PRIVATE_KEY TLS_PRIVATE_KEY_FILE
load_file TLS_CA_CERTIFICATE TLS_CA_CERTIFICATE_FILE

[ -n "${ROUTE_HOST:-}" ] || die "ROUTE_HOST is required (the Route host, not a URL)"
case "$ROUTE_HOST" in
  *://*) die "ROUTE_HOST must be a hostname (got '$ROUTE_HOST'). Drop the scheme." ;;
esac
[ -n "${TARGET_SERVICE:-}" ] || die "TARGET_SERVICE is required"
if [ -z "${ROUTE_NAME:-}" ]; then
  ROUTE_NAME="${GITHUB_REPOSITORY##*/}-vanity-url"
fi
[ -n "$ROUTE_NAME" ] && [ "$ROUTE_NAME" != "-vanity-url" ] || die "ROUTE_NAME is required"
[ -n "${TLS_CERTIFICATE:-}" ] || die "TLS_CERTIFICATE or TLS_CERTIFICATE_FILE is required"
[ -n "${TLS_PRIVATE_KEY:-}" ] || die "TLS_PRIVATE_KEY or TLS_PRIVATE_KEY_FILE is required"
[ -n "${TLS_CA_CERTIFICATE:-}" ] || die "TLS_CA_CERTIFICATE or TLS_CA_CERTIFICATE_FILE is required"

umask 077
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

CERT_PEM="$WORKDIR/cert.pem"
KEY_PEM="$WORKDIR/key.pem"
CA_PEM="$WORKDIR/ca.pem"
printf '%s\n' "$TLS_CERTIFICATE" > "$CERT_PEM"
printf '%s\n' "$TLS_PRIVATE_KEY" > "$KEY_PEM"
printf '%s\n' "$TLS_CA_CERTIFICATE" > "$CA_PEM"

echo "Validating certificate, private key and CA chain. PEM contents are not printed."
cert_count="$(grep -c -e '-----BEGIN CERTIFICATE-----' "$CERT_PEM" || true)"
[ "$cert_count" -eq 1 ] || die "TLS_CERTIFICATE must hold only the leaf certificate (found ${cert_count}). Put the issuing CA in TLS_CA_CERTIFICATE."
if ! CERT_PUB_SHA="$(openssl x509 -in "$CERT_PEM" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | sha256sum | cut -d' ' -f1)"; then
  die "TLS certificate is invalid."
fi
if ! KEY_PUB_SHA="$(openssl pkey -in "$KEY_PEM" -passin pass: -pubout -outform der 2>/dev/null | sha256sum | cut -d' ' -f1)"; then
  die "TLS private key is invalid or encrypted."
fi
if [ -z "$CERT_PUB_SHA" ] || [ -z "$KEY_PUB_SHA" ] || [ "$CERT_PUB_SHA" != "$KEY_PUB_SHA" ]; then
  die "TLS certificate and private key do not match."
fi
echo "PASS: private key matches the certificate"

if ! openssl x509 -in "$CERT_PEM" -noout -checkend 0 >/dev/null 2>&1; then
  die "Certificate has expired."
fi
if ! openssl x509 -in "$CERT_PEM" -noout -checkend 1209600 >/dev/null 2>&1; then
  echo "warning: certificate expires within 14 days"
fi
echo "PASS: certificate is not expired"

# Chain order: CA 1 issued the leaf, and each later CA issued the one before it.
ca_count="$(grep -c -e '-----BEGIN CERTIFICATE-----' "$CA_PEM" || true)"
[ "$ca_count" -ge 1 ] || die "TLS_CA_CERTIFICATE holds no certificate."
[ "$(grep -c -e '-----BEGIN ' "$CA_PEM")" -eq "$ca_count" ] || die "TLS_CA_CERTIFICATE must hold only certificates."
awk -v dir="$WORKDIR" '/-----BEGIN CERTIFICATE-----/ { n++ } n { print > (dir "/ca-" n ".pem") }' "$CA_PEM"
child="$CERT_PEM"
child_name="TLS_CERTIFICATE"
for i in $(seq 1 "$ca_count"); do
  ca="${WORKDIR}/ca-${i}.pem"
  openssl x509 -in "$ca" -noout >/dev/null 2>&1 || die "TLS_CA_CERTIFICATE certificate ${i} is invalid."
  openssl x509 -in "$ca" -noout -checkend 0 >/dev/null 2>&1 || die "TLS_CA_CERTIFICATE certificate ${i} has expired."
  if ! openssl verify -partial_chain -trusted "$ca" "$child" >/dev/null 2>&1; then
    die "TLS_CA_CERTIFICATE certificate ${i} did not issue ${child_name}. List the issuing CA first, then each CA after the one it issued."
  fi
  child="$ca"
  child_name="TLS_CA_CERTIFICATE certificate ${i}"
done
echo "PASS: CA chain (${ca_count} certificate(s)) issued the certificate, in order, none expired"

if ! cert_covers_host "$CERT_PEM" "$ROUTE_HOST"; then
  die "Certificate does not cover host '$ROUTE_HOST' (CN/SAN mismatch)."
fi
echo "PASS: certificate covers ${ROUTE_HOST}"

openssl x509 -in "$CERT_PEM" -noout -subject -issuer -dates
openssl x509 -in "$CERT_PEM" -noout -ext subjectAltName 2>/dev/null || true

if [ "$DRY_RUN" = "true" ]; then
  ROUTE_OUT="${ROUTE_OUT:-route.yml}"
else
  ROUTE_OUT="${RUNNER_TEMP:-$WORKDIR}/route.yml"
fi

{
  cat <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${ROUTE_NAME}
spec:
  host: ${ROUTE_HOST}
  to:
    kind: Service
    name: ${TARGET_SERVICE}
    weight: 100
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
    certificate: |
EOF
  printf '%s\n' "$TLS_CERTIFICATE" | sed 's/^/      /'
  echo "    key: |"
  printf '%s\n' "$TLS_PRIVATE_KEY" | sed 's/^/      /'
  echo "    caCertificate: |"
  printf '%s\n' "$TLS_CA_CERTIFICATE" | sed 's/^/      /'
} > "$ROUTE_OUT"

if ! grep -q '^    certificate: |' "$ROUTE_OUT" || ! grep -q '^    key: |' "$ROUTE_OUT"; then
  die "Generated Route YAML is missing spec.tls.certificate/key."
fi
grep -q '^    caCertificate: |' "$ROUTE_OUT" || die "caCertificate was not nested under spec.tls."
grep -q '^  caCertificate:' "$ROUTE_OUT" && die "caCertificate was written as a spec sibling; expected spec.tls.caCertificate."

[ -n "$OC_NAMESPACE" ] || die "OC_NAMESPACE is required"
[ -n "$OC_SERVER" ] || die "OC_SERVER is required"
[ -n "$OC_TOKEN" ] || die "OC_TOKEN is required"
command -v oc >/dev/null || die "oc is not on PATH"

if oc whoami >/dev/null 2>&1; then
  oc project "$OC_NAMESPACE" >/dev/null || die "oc is logged in, but not to namespace $OC_NAMESPACE"
else
  oc login --server="$OC_SERVER" --token="$OC_TOKEN" --insecure-skip-tls-verify=true >/dev/null
  oc project "$OC_NAMESPACE" >/dev/null
fi

# --ignore-not-found: absence is empty output. Any other failure is an error.
if ! route_ref="$(oc get route "$ROUTE_NAME" --ignore-not-found -o name)"; then
  die "Could not read Route ${ROUTE_NAME}."
fi

# OpenShift admits one route per host. A second name is created and then Rejected.
if ! host_rows="$(oc get route -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.spec.host}{"\n"}{end}')"; then
  die "Could not list Routes."
fi
while IFS=$'\t' read -r other_name other_host; do
  [ -n "$other_name" ] || continue
  if [ "$other_host" = "$ROUTE_HOST" ] && [ "$other_name" != "$ROUTE_NAME" ]; then
    die "Host ${ROUTE_HOST} is already claimed by route ${other_name}. ${ROUTE_NAME} would be rejected."
  fi
done <<< "$host_rows"

if [ "$DRY_RUN" = "true" ]; then
  if [ -n "$route_ref" ]; then
    route_state="Route ${ROUTE_NAME} exists."
  else
    route_state="Route ${ROUTE_NAME} does not exist."
  fi
  echo "DRY RUN: cert/key match, host covered, logged in. ${route_state} No Secret and no apply. YAML at $ROUTE_OUT (contains the private key; not printed)."
  summarize "dry_run=true. Validated ${ROUTE_HOST}. ${route_state} The route was not changed."
  exit 0
fi

if [ -n "$route_ref" ]; then
  echo "Existing route found. Archiving working certificates..."
  OLD_CERT="$(oc get route "$ROUTE_NAME" -o jsonpath='{.spec.tls.certificate}')"
  OLD_KEY="$(oc get route "$ROUTE_NAME" -o jsonpath='{.spec.tls.key}')"
  OLD_CA="$(oc get route "$ROUTE_NAME" -o jsonpath='{.spec.tls.caCertificate}')"
  if [ -n "$OLD_KEY" ]; then
    CERT_HASH="$(printf '%s' "$OLD_CERT" | sha256sum | cut -d' ' -f1)"
    BACKUP_NAME="${ROUTE_NAME}-backup-${CERT_HASH:0:8}"
    if oc get secret "$BACKUP_NAME" >/dev/null 2>&1; then
      echo "Backup already exists: $BACKUP_NAME"
    else
      oc create secret generic "$BACKUP_NAME" \
        --from-literal=tls.crt="$OLD_CERT" \
        --from-literal=tls.key="$OLD_KEY" \
        --from-literal=ca.crt="$OLD_CA"
      oc label secret "$BACKUP_NAME" backup-type=route-tls
      echo "Certificates archived to secret: $BACKUP_NAME"
    fi
  else
    echo "Route ${ROUTE_NAME} has no inline key. Nothing to back up."
  fi
else
  echo "No existing route found. Skipping archival backup."
fi

oc apply -f "$ROUTE_OUT"

if ! LIVE_CERT="$(oc get route "$ROUTE_NAME" -o jsonpath='{.spec.tls.certificate}')"; then
  die "Could not read Route ${ROUTE_NAME} after apply."
fi
[ -n "$LIVE_CERT" ] || die "Route ${ROUTE_NAME} has no certificate after apply."
if ! LIVE_PUB_SHA="$(printf '%s\n' "$LIVE_CERT" | openssl x509 -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | sha256sum | cut -d' ' -f1)"; then
  die "Route ${ROUTE_NAME} certificate could not be read after apply."
fi
if [ -z "$LIVE_PUB_SHA" ] || [ "$LIVE_PUB_SHA" != "$CERT_PUB_SHA" ]; then
  die "Route ${ROUTE_NAME} certificate does not match the certificate that was applied."
fi
if ! LIVE_NOT_AFTER="$(printf '%s\n' "$LIVE_CERT" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"; then
  die "Route ${ROUTE_NAME} certificate expiry could not be read after apply."
fi
[ -n "$LIVE_NOT_AFTER" ] || die "Route ${ROUTE_NAME} certificate has no expiry after apply."

echo "Applied route $ROUTE_NAME -> $TARGET_SERVICE (host $ROUTE_HOST). Certificate expires ${LIVE_NOT_AFTER}."
summarize "dry_run=false. Applied route ${ROUTE_NAME} to ${TARGET_SERVICE} for ${ROUTE_HOST}. Certificate expires ${LIVE_NOT_AFTER}."
