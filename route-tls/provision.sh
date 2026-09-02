#!/usr/bin/env bash
# OpenShift Route TLS. GitHub Action wrapper: action.yml.
# Run this file locally with the same env vars.
set -euo pipefail

DRY_RUN="${DRY_RUN:-false}"
INSECURE_SKIP_TLS_VERIFY="${INSECURE_SKIP_TLS_VERIFY:-true}"
APP="${APP:-}"
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

die() { err "$1"; exit 1; }

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
  local host="$1" name="$2"
  [ "$name" = "$host" ] && return 0
  if [ "${name#\*.}" != "$name" ]; then
    local suffix="${name#\*}"
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
[ -n "${ROUTE_NAME:-}" ] || die "ROUTE_NAME is required"
[ -n "${TARGET_SERVICE:-}" ] || die "TARGET_SERVICE is required"
[ -n "${TLS_CERTIFICATE:-}" ] || die "TLS_CERTIFICATE or TLS_CERTIFICATE_FILE is required"
[ -n "${TLS_PRIVATE_KEY:-}" ] || die "TLS_PRIVATE_KEY or TLS_PRIVATE_KEY_FILE is required"
if [ -z "$APP" ]; then
  APP="$TARGET_SERVICE"
fi

if [ "$DRY_RUN" != "true" ]; then
  [ -n "$OC_NAMESPACE" ] || die "OC_NAMESPACE is required unless DRY_RUN=true"
  [ -n "$OC_SERVER" ] || die "OC_SERVER is required unless DRY_RUN=true"
  [ -n "$OC_TOKEN" ] || die "OC_TOKEN is required unless DRY_RUN=true"
fi

umask 077
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

ensure_oc() {
  if command -v oc >/dev/null 2>&1; then
    return 0
  fi
  [ -n "${GITHUB_ACTIONS:-}" ] || die "oc is not on PATH (install the OpenShift CLI, or use DRY_RUN=true)"
  echo "Installing oc from the OpenShift client mirror..."
  local tarball="$WORKDIR/oc.tgz"
  curl -fsSL -o "$tarball" \
    "${OC_CLIENT_URL:-https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz}"
  tar -xzf "$tarball" -C "$WORKDIR" oc
  PATH="$WORKDIR:$PATH"
  export PATH
  command -v oc >/dev/null || die "failed to install oc"
}

if [ "$DRY_RUN" != "true" ]; then
  ensure_oc
fi

CERT_PEM="$WORKDIR/cert.pem"
KEY_PEM="$WORKDIR/key.pem"
printf '%s\n' "$TLS_CERTIFICATE" > "$CERT_PEM"
printf '%s\n' "$TLS_PRIVATE_KEY" > "$KEY_PEM"

echo "Validating certificate and private key..."
CERT_PUB_SHA="$(openssl x509 -in "$CERT_PEM" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | sha256sum | cut -d' ' -f1)"
KEY_PUB_SHA="$(openssl pkey -in "$KEY_PEM" -pubout -outform der 2>/dev/null | sha256sum | cut -d' ' -f1)"
if [ -z "$CERT_PUB_SHA" ] || [ -z "$KEY_PUB_SHA" ] || [ "$CERT_PUB_SHA" != "$KEY_PUB_SHA" ]; then
  die "TLS certificate and private key are invalid or do not match."
fi

if ! openssl x509 -in "$CERT_PEM" -noout -checkend 0 >/dev/null 2>&1; then
  die "Certificate has expired."
fi
if ! openssl x509 -in "$CERT_PEM" -noout -checkend 1209600 >/dev/null 2>&1; then
  echo "warning: certificate expires within 14 days"
fi

if ! cert_covers_host "$CERT_PEM" "$ROUTE_HOST"; then
  die "Certificate does not cover host '$ROUTE_HOST' (CN/SAN mismatch)."
fi

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
  labels:
    app: ${APP}
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
  if [ -n "$TLS_CA_CERTIFICATE" ]; then
    echo "    caCertificate: |"
    printf '%s\n' "$TLS_CA_CERTIFICATE" | sed 's/^/      /'
  fi
} > "$ROUTE_OUT"

if ! grep -q '^    certificate: |' "$ROUTE_OUT" || ! grep -q '^    key: |' "$ROUTE_OUT"; then
  die "Generated Route YAML is missing spec.tls.certificate/key."
fi
if [ -n "$TLS_CA_CERTIFICATE" ]; then
  grep -q '^    caCertificate: |' "$ROUTE_OUT" || die "caCertificate was not nested under spec.tls."
  grep -q '^  caCertificate:' "$ROUTE_OUT" && die "caCertificate was written as a spec sibling; expected spec.tls.caCertificate."
fi

if [ "$DRY_RUN" = "true" ]; then
  echo "DRY RUN: cert/key match, host covered, YAML written to $ROUTE_OUT (contains the private key; not printed)."
  exit 0
fi

oc login --server="$OC_SERVER" --token="$OC_TOKEN" --insecure-skip-tls-verify="$INSECURE_SKIP_TLS_VERIFY" >/dev/null
oc project "$OC_NAMESPACE" >/dev/null

if oc get route "$ROUTE_NAME" >/dev/null 2>&1; then
  echo "Existing route found. Archiving working certificates..."
  OLD_CERT="$(oc get route "$ROUTE_NAME" -o jsonpath='{.spec.tls.certificate}')"
  OLD_KEY="$(oc get route "$ROUTE_NAME" -o jsonpath='{.spec.tls.key}')"
  if [ -n "$OLD_KEY" ]; then
    CERT_HASH="$(printf '%s' "$OLD_CERT" | sha256sum | cut -d' ' -f1)"
    BACKUP_NAME="${ROUTE_NAME}-backup-${CERT_HASH:0:8}"
    if oc get secret "$BACKUP_NAME" >/dev/null 2>&1; then
      echo "Backup already exists: $BACKUP_NAME"
    else
      oc create secret generic "$BACKUP_NAME" \
        --from-literal=tls.crt="$OLD_CERT" \
        --from-literal=tls.key="$OLD_KEY"
      oc label secret "$BACKUP_NAME" backup-type=route-tls app="$APP"
      echo "Certificates archived to secret: $BACKUP_NAME"
    fi
  fi
else
  echo "No existing route found. Skipping archival backup."
fi

oc apply -f "$ROUTE_OUT"
echo "Applied route $ROUTE_NAME -> $TARGET_SERVICE (host $ROUTE_HOST)"
