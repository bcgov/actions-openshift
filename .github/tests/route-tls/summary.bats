#!/usr/bin/env bats
# route-tls summary records dry_run without printing the private key

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../route-tls/provision.sh"
  WORK="${BATS_TEST_TMPDIR}/work"
  mkdir -p "$WORK"
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  : > "$GITHUB_STEP_SUMMARY"
  openssl req -x509 -newkey rsa:2048 -keyout "${BATS_TEST_TMPDIR}/ca.key" -out "${BATS_TEST_TMPDIR}/ca.pem" -days 30 -nodes -subj "/CN=Test CA"
  openssl req -newkey rsa:2048 -keyout "${BATS_TEST_TMPDIR}/leaf.key" -out "${BATS_TEST_TMPDIR}/leaf.csr" -nodes -subj "/CN=app.example.gov.bc.ca"
  printf 'subjectAltName=DNS:app.example.gov.bc.ca\n' > "${BATS_TEST_TMPDIR}/ext.cnf"
  openssl x509 -req -in "${BATS_TEST_TMPDIR}/leaf.csr" -CA "${BATS_TEST_TMPDIR}/ca.pem" -CAkey "${BATS_TEST_TMPDIR}/ca.key" -CAcreateserial -out "${BATS_TEST_TMPDIR}/leaf.pem" -days 30 -extfile "${BATS_TEST_TMPDIR}/ext.cnf"
}

@test "dry run logs in, reads the route, and does not write" {
  bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$bin"
  export OC_LOG="${BATS_TEST_TMPDIR}/oc.log"
  : > "$OC_LOG"
  cat > "${bin}/oc" << 'STUB'
#!/bin/bash
echo "$*" >> "$OC_LOG"
case "$1" in
  whoami) exit 1 ;;
  get) exit 0 ;;
  create|apply) exit 99 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "${bin}/oc"
  cd "$WORK"
  run env \
    PATH="${bin}:${PATH}" \
    OC_LOG="$OC_LOG" \
    ROUTE_HOST=app.example.gov.bc.ca \
    ROUTE_NAME=app-vanity \
    TARGET_SERVICE=app \
    TLS_CERTIFICATE_FILE="${BATS_TEST_TMPDIR}/leaf.pem" \
    TLS_PRIVATE_KEY_FILE="${BATS_TEST_TMPDIR}/leaf.key" \
    TLS_CA_CERTIFICATE_FILE="${BATS_TEST_TMPDIR}/ca.pem" \
    OC_NAMESPACE=abc123-prod \
    OC_SERVER=https://api.example.test:6443 \
    OC_TOKEN=token-should-not-leak \
    DRY_RUN=true \
    ROUTE_OUT="${WORK}/route.yml" \
    GITHUB_STEP_SUMMARY="$GITHUB_STEP_SUMMARY" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice title=Route TLS::dry_run=true"* ]]
  grep -F 'dry_run=true' "$GITHUB_STEP_SUMMARY"
  grep -F 'not changed' "$GITHUB_STEP_SUMMARY"
  grep -F 'login' "$OC_LOG"
  grep -F 'get route app-vanity' "$OC_LOG"
  ! grep -E '^(create|apply) ' "$OC_LOG"
  ! grep -F 'token-should-not-leak' "$GITHUB_STEP_SUMMARY"
  ! grep -F 'BEGIN PRIVATE KEY' "$GITHUB_STEP_SUMMARY"
}

@test "failed oc apply records the line and exit status, not the token" {
  bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$bin"
  cat > "${bin}/oc" << 'STUB'
#!/bin/bash
case "$1" in
  get) exit 1 ;;
  apply) exit 3 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "${bin}/oc"
  apply_line="$(grep -n '^oc apply -f ' "$SCRIPT" | cut -d: -f1)"
  cd "$WORK"
  run env \
    PATH="${bin}:${PATH}" \
    ROUTE_HOST=app.example.gov.bc.ca \
    ROUTE_NAME=app-vanity \
    TARGET_SERVICE=app \
    TLS_CERTIFICATE_FILE="${BATS_TEST_TMPDIR}/leaf.pem" \
    TLS_PRIVATE_KEY_FILE="${BATS_TEST_TMPDIR}/leaf.key" \
    TLS_CA_CERTIFICATE_FILE="${BATS_TEST_TMPDIR}/ca.pem" \
    OC_NAMESPACE=example-prod \
    OC_SERVER=https://api.example.test:6443 \
    OC_TOKEN=token-should-not-leak \
    DRY_RUN=false \
    ROUTE_OUT="${WORK}/route.yml" \
    GITHUB_STEP_SUMMARY="$GITHUB_STEP_SUMMARY" \
    "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -F "dry_run=false. Failed: Command failed at line ${apply_line} (exit status 3)." "$GITHUB_STEP_SUMMARY"
  ! grep -F 'token-should-not-leak' "$GITHUB_STEP_SUMMARY"
  ! grep -F 'BEGIN PRIVATE KEY' "$GITHUB_STEP_SUMMARY"
}

@test "failure records dry_run on the summary" {
  cd "$WORK"
  run env \
    ROUTE_HOST=other.example.gov.bc.ca \
    ROUTE_NAME=app-vanity \
    TARGET_SERVICE=app \
    TLS_CERTIFICATE_FILE="${BATS_TEST_TMPDIR}/leaf.pem" \
    TLS_PRIVATE_KEY_FILE="${BATS_TEST_TMPDIR}/leaf.key" \
    TLS_CA_CERTIFICATE_FILE="${BATS_TEST_TMPDIR}/ca.pem" \
    DRY_RUN=false \
    ROUTE_OUT="${WORK}/route.yml" \
    GITHUB_STEP_SUMMARY="$GITHUB_STEP_SUMMARY" \
    "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -F 'dry_run=false' "$GITHUB_STEP_SUMMARY"
  ! grep -F 'BEGIN PRIVATE KEY' "$GITHUB_STEP_SUMMARY"
}
