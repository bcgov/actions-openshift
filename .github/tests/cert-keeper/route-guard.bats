#!/usr/bin/env bats
# route-guard.sh stops cert-keeper from rewriting a Route that is not the
# host's own, before any certificate is issued.

setup() {
  GUARD="${BATS_TEST_DIRNAME}/../../../cert-keeper/route-guard.sh"
  export ROUTE_NAME=app-vanity HOST=app.example.gov.bc.ca TARGET_SERVICE=app-frontend
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat > "${BATS_TEST_TMPDIR}/bin/oc" << 'STUB'
#!/bin/bash
[ -z "${OC_FAIL-}" ] || { echo "Unable to connect to the server" >&2; exit 1; }
printf '%s' "${ROUTE_ROW-}"
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/oc"
  export OC="${BATS_TEST_TMPDIR}/bin/oc"
}

@test "no Route yet: fine, the install step creates it" {
  ROUTE_ROW='' run bash "$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not exist yet"* ]]
}

@test "same host with edge termination: fine" {
  ROUTE_ROW='app.example.gov.bc.ca|edge|app-frontend' run bash "$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is the Route for app.example.gov.bc.ca (edge)"* ]]
  [[ "$output" != *"::warning"* ]]
}

@test "same host with no TLS yet: fine, and the host match ignores case" {
  ROUTE_ROW='APP.example.gov.bc.ca||app-frontend' run bash "$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no TLS yet"* ]]
}

@test "a Route for another host is refused with a Fix line" {
  ROUTE_ROW='other.example.com|edge|other-svc' run bash "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=cert-keeper::Route app-vanity serves 'other.example.com', not 'app.example.gov.bc.ca'"* ]]
  [[ "$output" == *"Fix: "* ]]
}

@test "passthrough and reencrypt Routes are refused" {
  for term in passthrough reencrypt; do
    ROUTE_ROW="app.example.gov.bc.ca|${term}|app-frontend" run bash "$GUARD"
    [ "$status" -eq 1 ]
    [[ "$output" == *"uses ${term} termination; cert-keeper would change it to edge"* ]]
    [[ "$output" == *"Fix: "* ]]
  done
}

@test "a different backend service only warns" {
  ROUTE_ROW='app.example.gov.bc.ca|edge|old-service' run bash "$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning title=cert-keeper::Route app-vanity sends traffic to 'old-service'; it will be changed to 'app-frontend'"* ]]
}

@test "an unreadable API fails loudly instead of assuming the Route is absent" {
  OC_FAIL=1 run bash "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not read Route app-vanity"* ]]
  [[ "$output" == *"Fix: "* ]]
}

@test "missing inputs fail" {
  ROUTE_NAME='' run bash "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ROUTE_NAME and HOST are required"* ]]
}
