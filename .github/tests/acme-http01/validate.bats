#!/usr/bin/env bats
# acme-http01 rejects bad input before touching a cluster and renders a
# plain-HTTP, path-scoped challenge Route

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../acme-http01/issue.sh"
  export ACME_HOST=app.example.gov.bc.ca ACME_EMAIL=ops@example.gov.bc.ca OC=false
  unset GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_STEP_SUMMARY
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
  [[ "$output" == *"path: /.well-known/acme-challenge/"* ]]
  [[ "$output" != *"tls:"* ]]
  [[ "$output" == *"host: app.example.gov.bc.ca"* ]]
}
