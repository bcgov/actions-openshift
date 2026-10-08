#!/usr/bin/env bats
# route-tls validates the cert, key and CA chain order, backs up before apply,
# and prints only names and results

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../route-tls/provision.sh"
  D="$BATS_TEST_TMPDIR"
  printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "${D}/ca.cnf"
  printf 'subjectAltName=DNS:app.example.gov.bc.ca\n' > "${D}/leaf.cnf"
  openssl req -x509 -newkey rsa:2048 -keyout "${D}/root.key" -out "${D}/root.pem" -days 30 -nodes -subj "/CN=Test Root" 2>/dev/null
  openssl req -newkey rsa:2048 -keyout "${D}/int.key" -out "${D}/int.csr" -nodes -subj "/CN=Test Issuing CA" 2>/dev/null
  openssl x509 -req -in "${D}/int.csr" -CA "${D}/root.pem" -CAkey "${D}/root.key" -CAcreateserial -out "${D}/int.pem" -days 30 -extfile "${D}/ca.cnf" 2>/dev/null
  openssl x509 -req -in "${D}/int.csr" -CA "${D}/root.pem" -CAkey "${D}/root.key" -CAcreateserial -out "${D}/int-expired.pem" -not_before 20200101000000Z -not_after 20210101000000Z -extfile "${D}/ca.cnf" 2>/dev/null
  openssl req -newkey rsa:2048 -keyout "${D}/leaf.key" -out "${D}/leaf.csr" -nodes -subj "/CN=app.example.gov.bc.ca" 2>/dev/null
  openssl x509 -req -in "${D}/leaf.csr" -CA "${D}/int.pem" -CAkey "${D}/int.key" -CAcreateserial -out "${D}/leaf.pem" -days 30 -extfile "${D}/leaf.cnf" 2>/dev/null
  openssl x509 -req -in "${D}/leaf.csr" -CA "${D}/int.pem" -CAkey "${D}/int.key" -CAcreateserial -out "${D}/leaf-expired.pem" -not_before 20200101000000Z -not_after 20210101000000Z -extfile "${D}/leaf.cnf" 2>/dev/null
  openssl pkey -in "${D}/leaf.key" -aes256 -passout pass:secret -out "${D}/leaf-encrypted.key"
  cat "${D}/int.pem" "${D}/root.pem" > "${D}/chain.pem"
  cat "${D}/root.pem" "${D}/int.pem" > "${D}/chain-reversed.pem"

  # oc stub: the route exists with an inline key unless ROUTE_KEY is empty
  bin="${D}/bin"
  mkdir -p "$bin"
  export OC_LOG="${D}/oc.log"
  : > "$OC_LOG"
  cat > "${bin}/oc" << 'STUB'
#!/bin/bash
echo "$1 $2 $3" >> "$OC_LOG"
case "$1" in
  whoami) exit 1 ;;
  get)
    case "$*" in
      *spec.host*) ;;
      *caCertificate*) printf 'ca\n' ;;
      *spec.tls.key*) printf '%s' "$ROUTE_KEY" ;;
      *spec.tls.certificate*) cat "$LEAF" ;;
      "get secret "*) exit 1 ;;
      *) printf 'route.route.openshift.io/%s\n' "$3" ;;
    esac
    ;;
esac
exit 0
STUB
  chmod +x "${bin}/oc"
  cd "$D"
}

provision() {
  # $1 cert, $2 key, $3 CA, $4 dry run
  run env \
    PATH="${D}/bin:${PATH}" \
    OC_LOG="$OC_LOG" \
    LEAF="${D}/leaf.pem" \
    ROUTE_KEY="${ROUTE_KEY-present}" \
    ROUTE_HOST=app.example.gov.bc.ca \
    ROUTE_NAME=app-vanity \
    TARGET_SERVICE=app \
    TLS_CERTIFICATE_FILE="$1" \
    TLS_PRIVATE_KEY_FILE="$2" \
    TLS_CA_CERTIFICATE_FILE="$3" \
    OC_NAMESPACE=abc123-prod \
    OC_SERVER=https://api.example.test:6443 \
    OC_TOKEN=token-should-not-leak \
    DRY_RUN="${4:-true}" \
    ROUTE_OUT="${D}/route.yml" \
    RUNNER_TEMP="$D" \
    "$SCRIPT" < /dev/null
  [[ "$output" != *"BEGIN "* ]]
  [[ "$output" != *"token-should-not-leak"* ]]
}

@test "issuing CA then root passes and prints each check" {
  provision "${D}/leaf.pem" "${D}/leaf.key" "${D}/chain.pem"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: private key matches the certificate"* ]]
  [[ "$output" == *"PASS: certificate is not expired"* ]]
  [[ "$output" == *"PASS: CA chain (2 certificate(s)) issued the certificate, in order, none expired"* ]]
  [[ "$output" == *"PASS: certificate covers app.example.gov.bc.ca"* ]]
}

@test "issuing CA alone passes" {
  provision "${D}/leaf.pem" "${D}/leaf.key" "${D}/int.pem"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: CA chain (1 certificate(s))"* ]]
}

@test "root before the issuing CA fails on chain order" {
  provision "${D}/leaf.pem" "${D}/leaf.key" "${D}/chain-reversed.pem"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TLS_CA_CERTIFICATE certificate 1 did not issue TLS_CERTIFICATE."* ]]
}

@test "a CA that did not issue the one before it fails" {
  cat "${D}/int.pem" "${D}/leaf.pem" > "${D}/chain-bad.pem"
  provision "${D}/leaf.pem" "${D}/leaf.key" "${D}/chain-bad.pem"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TLS_CA_CERTIFICATE certificate 2 did not issue TLS_CA_CERTIFICATE certificate 1."* ]]
}

@test "a repeated issuing CA fails" {
  cat "${D}/int.pem" "${D}/int.pem" "${D}/root.pem" > "${D}/chain-repeat.pem"
  provision "${D}/leaf.pem" "${D}/leaf.key" "${D}/chain-repeat.pem"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TLS_CA_CERTIFICATE certificate 2 did not issue TLS_CA_CERTIFICATE certificate 1."* ]]
}

@test "a repeated self-signed certificate passes" {
  openssl req -x509 -newkey rsa:2048 -keyout "${D}/self.key" -out "${D}/self.pem" -days 30 -nodes -subj "/CN=app.example.gov.bc.ca" -addext "subjectAltName=DNS:app.example.gov.bc.ca" 2>/dev/null
  provision "${D}/self.pem" "${D}/self.key" "${D}/self.pem"
  [ "$status" -eq 0 ]
}

@test "expired certificate fails as expired, not as a chain error" {
  provision "${D}/leaf-expired.pem" "${D}/leaf.key" "${D}/int.pem"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Certificate has expired."* ]]
  [[ "$output" != *"did not issue"* ]]
}

@test "expired CA fails" {
  provision "${D}/leaf.pem" "${D}/leaf.key" "${D}/int-expired.pem"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TLS_CA_CERTIFICATE certificate 1 has expired."* ]]
}

@test "full chain in TLS_CERTIFICATE fails" {
  cat "${D}/leaf.pem" "${D}/int.pem" > "${D}/fullchain.pem"
  provision "${D}/fullchain.pem" "${D}/leaf.key" "${D}/int.pem"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TLS_CERTIFICATE must hold only the leaf certificate (found 2)."* ]]
}

@test "private key in the CA bundle fails without printing it" {
  cat "${D}/int.pem" "${D}/leaf.key" > "${D}/ca-with-key.pem"
  provision "${D}/leaf.pem" "${D}/leaf.key" "${D}/ca-with-key.pem"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TLS_CA_CERTIFICATE must hold only certificate PEM blocks, with no other text or keys."* ]]
}

@test "text around the CA certificate fails" {
  { echo "subject=CN=Test Issuing CA"; cat "${D}/int.pem"; } > "${D}/ca-with-text.pem"
  provision "${D}/leaf.pem" "${D}/leaf.key" "${D}/ca-with-text.pem"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TLS_CA_CERTIFICATE must hold only certificate PEM blocks"* ]]
}

@test "private key after the leaf fails without printing it" {
  cat "${D}/leaf.pem" "${D}/leaf.key" > "${D}/leaf-with-key.pem"
  provision "${D}/leaf-with-key.pem" "${D}/leaf.key" "${D}/int.pem"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TLS_CERTIFICATE must hold only the certificate PEM block, with no other text or keys."* ]]
}

@test "encrypted private key fails without prompting" {
  provision "${D}/leaf.pem" "${D}/leaf-encrypted.key" "${D}/int.pem"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TLS private key is invalid or encrypted."* ]]
}

@test "existing route TLS is backed up before apply" {
  provision "${D}/leaf.pem" "${D}/leaf.key" "${D}/int.pem" false
  [ "$status" -eq 0 ]
  [[ "$output" == *"Certificates archived to secret: app-vanity-backup-"* ]]
  create="$(grep -n '^create secret generic' "$OC_LOG" | cut -d: -f1)"
  apply="$(grep -n '^apply ' "$OC_LOG" | cut -d: -f1)"
  [ -n "$create" ] && [ -n "$apply" ] && [ "$create" -lt "$apply" ]
}

@test "route without an inline key says there is nothing to back up" {
  ROUTE_KEY='' provision "${D}/leaf.pem" "${D}/leaf.key" "${D}/int.pem" false
  [ "$status" -eq 0 ]
  [[ "$output" == *"Route app-vanity has no inline key. Nothing to back up."* ]]
  ! grep -q '^create ' "$OC_LOG"
}
