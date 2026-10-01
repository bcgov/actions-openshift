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

@test "dry run records dry_run=true on the summary and does not print the key" {
  cd "$WORK"
  run env \
    ROUTE_HOST=app.example.gov.bc.ca \
    ROUTE_NAME=app-vanity \
    TARGET_SERVICE=app \
    TLS_CERTIFICATE_FILE="${BATS_TEST_TMPDIR}/leaf.pem" \
    TLS_PRIVATE_KEY_FILE="${BATS_TEST_TMPDIR}/leaf.key" \
    TLS_CA_CERTIFICATE_FILE="${BATS_TEST_TMPDIR}/ca.pem" \
    DRY_RUN=true \
    ROUTE_OUT="${WORK}/route.yml" \
    GITHUB_STEP_SUMMARY="$GITHUB_STEP_SUMMARY" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice title=Route TLS::dry_run=true"* ]]
  grep -F 'dry_run=true' "$GITHUB_STEP_SUMMARY"
  grep -F 'not changed' "$GITHUB_STEP_SUMMARY"
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
