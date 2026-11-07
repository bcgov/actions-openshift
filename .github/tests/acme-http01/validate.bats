#!/usr/bin/env bats
# acme-http01 rejects bad input before touching a cluster, renders a
# plain-HTTP path-scoped challenge Route, and (with a mocked oc) exercises
# apply → poll → PEM extract → outputs → EXIT cleanup.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../acme-http01/issue.sh"
  D="$BATS_TEST_TMPDIR"
  export ACME_HOST=app.example.gov.bc.ca ACME_EMAIL=ops@example.gov.bc.ca OC=false
  unset GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_STEP_SUMMARY
  unset RENDER_ONLY

  # Leaf + issuer for mocked success paths
  printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "${D}/ca.cnf"
  printf 'subjectAltName=DNS:app.example.gov.bc.ca\n' > "${D}/leaf.cnf"
  openssl req -x509 -newkey rsa:2048 -keyout "${D}/ca.key" -out "${D}/ca.pem" -days 30 -nodes -subj "/CN=Test Issuing CA" 2>/dev/null
  openssl req -newkey rsa:2048 -keyout "${D}/leaf.key" -out "${D}/leaf.csr" -nodes -subj "/CN=app.example.gov.bc.ca" 2>/dev/null
  openssl x509 -req -in "${D}/leaf.csr" -CA "${D}/ca.pem" -CAkey "${D}/ca.key" -CAcreateserial -out "${D}/leaf.pem" -days 30 -extfile "${D}/leaf.cnf" 2>/dev/null
  cat "${D}/leaf.pem" "${D}/ca.pem" > "${D}/fullchain.pem"

  bin="${D}/bin"
  mkdir -p "$bin"
  export OC_LOG="${D}/oc.log"
  : > "$OC_LOG"
  cat > "${bin}/oc" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$OC_LOG"
case "$1" in
  apply)
    cat >/dev/null
    exit 0
    ;;
  get)
    case "$*" in
      *lego*terminated*exitCode*)
        printf '%s' "${LEGO_EXIT-0}"
        ;;
      *Admitted*)
        printf '%s' "${ADMITTED-True}"
        ;;
      *waiting.reason*)
        printf '%s' "${WAITING-}"
        ;;
      *containerStatuses*name*state*)
        echo "mock container state"
        ;;
      events*|*" events "*)
        echo "mock event"
        ;;
      *helper*running*startedAt*)
        if [ "${HELPER_READY-1}" = "1" ]; then
          printf '2026-01-01T00:00:00Z'
        fi
        ;;
    esac
    exit 0
    ;;
  logs)
    echo "lego mock log"
    exit 0
    ;;
  exec)
    case "$*" in
      *.issuer.crt*) cat "$MOCK_CA" ;;
      *.key*) cat "$MOCK_KEY" ;;
      *.crt*) cat "$MOCK_FULLCHAIN" ;;
      *) exit 1 ;;
    esac
    exit 0
    ;;
  delete)
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "${bin}/oc"
}

issue() {
  run env \
    PATH="${D}/bin:${PATH}" \
    OC=oc \
    OC_LOG="$OC_LOG" \
    LEGO_EXIT="${LEGO_EXIT-0}" \
    ADMITTED="${ADMITTED-True}" \
    HELPER_READY="${HELPER_READY-1}" \
    WAITING="${WAITING-}" \
    MOCK_KEY="${D}/leaf.key" \
    MOCK_CA="${D}/ca.pem" \
    MOCK_FULLCHAIN="${D}/fullchain.pem" \
    ACME_HOST="${ACME_HOST}" \
    ACME_EMAIL="${ACME_EMAIL}" \
    ACME_SERVER="${ACME_SERVER:-staging}" \
    TIMEOUT="${TIMEOUT:-30}" \
    OUT_DIR="${D}/out" \
    RUNNER_TEMP="$D" \
    GITHUB_OUTPUT="${GITHUB_OUTPUT-}" \
    GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY-}" \
    bash "$SCRIPT" < /dev/null
}

@test "rejects wildcard host" {
  ACME_HOST='*.example.gov.bc.ca' run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *wildcard* ]]
}

@test "rejects scheme in host" {
  ACME_HOST='https://app.example.gov.bc.ca' run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "rejects bad email" {
  ACME_EMAIL='nope' run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "rejects unknown acme_server" {
  ACME_SERVER=other run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "staging is the default server" {
  RENDER_ONLY=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *acme-staging-v02* ]]
}

@test "production uses the production directory" {
  ACME_SERVER=production RENDER_ONLY=true run bash "$SCRIPT"
  [[ "$output" == *"https://acme-v02.api.letsencrypt.org/directory"* ]]
}

@test "challenge Route is path-scoped with no tls block" {
  RENDER_ONLY=true run bash "$SCRIPT"
  [[ "$output" == *"path: /.well-known/acme-challenge"* ]]
  [[ "$output" != *"tls:"* ]]
  [[ "$output" == *"host: app.example.gov.bc.ca"* ]]
}

@test "NetworkPolicy admits the router to the challenge Pod" {
  RENDER_ONLY=true run bash "$SCRIPT"
  [[ "$output" == *"kind: NetworkPolicy"* ]]
  [[ "$output" == *"network.openshift.io/policy-group: ingress"* ]]
}

@test "lego delays validation so the router can load the Route" {
  RENDER_ONLY=true run bash "$SCRIPT"
  [[ "$output" == *'--http.delay, "20s"'* ]]
}

@test "both containers use the digest-pinned lego image" {
  RENDER_ONLY=true run bash "$SCRIPT"
  [ "$(grep -c 'image: docker.io/goacme/lego:.*@sha256:' <<<"$output")" -eq 2 ]
  [ "$(grep -c 'image: ' <<<"$output")" -eq 2 ]
}

@test "email with quotes is YAML-escaped so it stays one arg" {
  ACME_EMAIL='ops"evil@example.gov.bc.ca' RENDER_ONLY=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'--email, "ops\"evil@example.gov.bc.ca"'* ]]
  [[ "$output" != *'", "--'* ]]
}

@test "mocked success writes leaf issuer key outputs and deletes resources" {
  export GITHUB_OUTPUT="${D}/github.output"
  : > "$GITHUB_OUTPUT"
  issue
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issued app.example.gov.bc.ca"* ]]
  grep -q '^tls_certificate<<' "$GITHUB_OUTPUT"
  grep -q '^tls_ca_certificate<<' "$GITHUB_OUTPUT"
  grep -q '^tls_private_key<<' "$GITHUB_OUTPUT"
  grep -q '^not_after=' "$GITHUB_OUTPUT"
  # PEM bodies landed in OUT_DIR and match fixtures
  cmp -s "${D}/out/tls.crt" "${D}/leaf.pem"
  cmp -s "${D}/out/ca.pem" "${D}/ca.pem"
  cmp -s "${D}/out/tls.key" "${D}/leaf.key"
  grep -E '^delete route/acme-http01-' "$OC_LOG"
  grep -E 'service/acme-http01-' "$OC_LOG"
  grep -E 'pod/acme-http01-' "$OC_LOG"
  grep -E 'networkpolicy/acme-http01-' "$OC_LOG"
  grep -E '^apply ' "$OC_LOG"
  grep -F 'helper' "$OC_LOG" | grep -F 'running.startedAt'
  grep -E '^exec ' "$OC_LOG"
}

@test "mocked lego failure still deletes created resources" {
  LEGO_EXIT=1 issue
  [ "$status" -eq 1 ]
  [[ "$output" == *"lego exited 1"* ]]
  grep -E '^delete route/acme-http01-' "$OC_LOG"
  grep -E 'service/acme-http01-' "$OC_LOG"
  grep -E 'pod/acme-http01-' "$OC_LOG"
  grep -E 'networkpolicy/acme-http01-' "$OC_LOG"
  ! grep -E '^exec ' "$OC_LOG"
}

@test "mocked rejected Route admission still deletes created resources" {
  # Empty lego exit so the loop checks admission
  LEGO_EXIT='' ADMITTED=False issue
  [ "$status" -eq 1 ]
  [[ "$output" == *"was not admitted"* ]]
  grep -E '^delete route/acme-http01-' "$OC_LOG"
  grep -E 'service/acme-http01-' "$OC_LOG"
  grep -E 'pod/acme-http01-' "$OC_LOG"
  grep -E 'networkpolicy/acme-http01-' "$OC_LOG"
  ! grep -E '^exec ' "$OC_LOG"
}

@test "mocked image pull failure stops early, explains and cleans up" {
  LEGO_EXIT='' WAITING='ImagePullBackOff ContainerCreating' issue
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot start: ImagePullBackOff"* ]]
  [[ "$output" == *"mock container state"* ]]
  [[ "$output" == *"mock event"* ]]
  grep -E '^delete route/acme-http01-' "$OC_LOG"
  ! grep -E '^exec ' "$OC_LOG"
}

@test "mocked timeout prints why the Pod did not finish" {
  LEGO_EXIT='' TIMEOUT=30 issue
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not finish within"* ]]
  [[ "$output" == *"mock event"* ]]
  grep -E '^delete route/acme-http01-' "$OC_LOG"
}
