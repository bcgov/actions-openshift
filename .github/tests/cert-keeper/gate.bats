#!/usr/bin/env bats
# cert-keeper's gate: decide.sh turns check.sh findings into due or not,
# and preflight.sh fails early when port 80 does not answer.

setup() {
  DECIDE="${BATS_TEST_DIRNAME}/../../../cert-keeper/decide.sh"
  PREFLIGHT="${BATS_TEST_DIRNAME}/../../../cert-keeper/preflight.sh"
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output" GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary"
  : > "$GITHUB_OUTPUT"
  export HOST=app.example.gov.bc.ca FORCE=false FINDINGS='[]'
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
}

finding() {
  # $1 status, $2 days_left, $3 lifetime_days
  printf '[{"host":"app.example.gov.bc.ca","status":"%s","not_before":"","not_after":"","days_left":"%s","lifetime_days":"%s"}]' "$1" "$2" "$3"
}

@test "no findings and no force: not due" {
  run bash "$DECIDE"
  [ "$status" -eq 0 ]
  grep -qx 'due=false' "$GITHUB_OUTPUT"
  [[ "$output" == *"not due for renewal"* ]]
}

@test "force makes a healthy certificate due" {
  FORCE=true run bash "$DECIDE"
  [ "$status" -eq 0 ]
  grep -qx 'due=true' "$GITHUB_OUTPUT"
  grep -qx 'reason=force is set' "$GITHUB_OUTPUT"
}

@test "uncovered is due: a brand-new host serving the router default" {
  FINDINGS="$(finding uncovered 140 198)" run bash "$DECIDE"
  [ "$status" -eq 0 ]
  grep -qx 'due=true' "$GITHUB_OUTPUT"
  grep -q 'does not cover it' "$GITHUB_OUTPUT"
}

@test "expiring is due and the reason states the lifetime" {
  FINDINGS="$(finding expiring 20 90)" run bash "$DECIDE"
  [ "$status" -eq 0 ]
  grep -qx 'due=true' "$GITHUB_OUTPUT"
  grep -q 'reason=20 of 90 days are left' "$GITHUB_OUTPUT"
}

@test "expired is due" {
  FINDINGS="$(finding expired -3 90)" run bash "$DECIDE"
  [ "$status" -eq 0 ]
  grep -qx 'due=true' "$GITHUB_OUTPUT"
}

@test "unreadable fails with a Fix line, even with force" {
  FINDINGS="$(finding unreadable '' '')" FORCE=true run bash "$DECIDE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=cert-keeper::Could not read a certificate"* ]]
  [[ "$output" == *"Fix: "* ]]
  ! grep -q '^due=' "$GITHUB_OUTPUT"
}

@test "findings for other hosts are ignored and host case does not matter" {
  FINDINGS='[{"host":"other.example.gov.bc.ca","status":"expired","days_left":"-1","lifetime_days":"90"}]' run bash "$DECIDE"
  grep -qx 'due=false' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  HOST=APP.example.gov.bc.ca FINDINGS="$(finding expiring 20 90)" run bash "$DECIDE"
  grep -qx 'due=true' "$GITHUB_OUTPUT"
}

@test "bad findings or unknown status fail loudly" {
  FINDINGS='not json' run bash "$DECIDE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"findings is not a JSON array"* ]]
  FINDINGS="$(finding mystery 1 1)" run bash "$DECIDE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unexpected status 'mystery'"* ]]
}

stub_curl() {
  printf '#!/bin/bash\nprintf "%%s" "%s"\nexit %s\n' "$1" "$2" > "${BATS_TEST_TMPDIR}/bin/curl"
  chmod +x "${BATS_TEST_TMPDIR}/bin/curl"
}

@test "preflight passes on any HTTP answer, including a redirect and a 503" {
  for code in 200 302 404 503; do
    stub_curl "$code" 0
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run bash "$PREFLIGHT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Port 80 answers for ${HOST} (HTTP ${code})"* ]]
  done
}

@test "preflight fails when port 80 does not answer" {
  stub_curl 000 7
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run bash "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=cert-keeper::Port 80 on ${HOST} did not answer"* ]]
  [[ "$output" == *"Fix: point ${HOST} at the OpenShift router"* ]]
}

parse_inputs() {
  local script="${BATS_TEST_TMPDIR}/parse-inputs.sh"
  awk '
    /^    - name: Parse Inputs$/ { in_step=1; next }
    in_step && /^      run: \|$/ { in_run=1; next }
    in_run && /^    - / { exit }
    in_run { sub(/^        /, ""); print }
  ' "${BATS_TEST_DIRNAME}/../../../cert-keeper/action.yml" > "$script"
  SHARED_INPUTS="${BATS_TEST_DIRNAME}/../../../shared/inputs.sh" bash "$script"
}

@test "parse inputs: default ACME mode sets supplied=false and dry_run=false" {
  INPUT_CA="" INPUT_FORCE="" INPUT_DRY_RUN="" HAS_CERT=false HAS_KEY=false HAS_CA=false run parse_inputs
  [ "$status" -eq 0 ]
  grep -qx 'ca=letsencrypt' "$GITHUB_OUTPUT"
  grep -qx 'force=false' "$GITHUB_OUTPUT"
  grep -qx 'dry_run=false' "$GITHUB_OUTPUT"
  grep -qx 'supplied=false' "$GITHUB_OUTPUT"
}

@test "parse inputs: pre-supplied mode sets supplied=true and allows dry_run" {
  INPUT_CA="" INPUT_FORCE="" INPUT_DRY_RUN="true" HAS_CERT=true HAS_KEY=true HAS_CA=true run parse_inputs
  [ "$status" -eq 0 ]
  grep -qx 'dry_run=true' "$GITHUB_OUTPUT"
  grep -qx 'supplied=true' "$GITHUB_OUTPUT"
}

@test "parse inputs: incomplete pre-supplied inputs fail with missing list" {
  INPUT_CA="" INPUT_FORCE="" INPUT_DRY_RUN="false" HAS_CERT=true HAS_KEY=false HAS_CA=true run parse_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=cert-keeper: incomplete certificate inputs::"* ]]
  [[ "$output" == *"missing: tls_private_key"* ]]
}

@test "parse inputs: dry_run=true without pre-supplied PEMs fails" {
  INPUT_CA="" INPUT_FORCE="" INPUT_DRY_RUN="true" HAS_CERT=false HAS_KEY=false HAS_CA=false run parse_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=dry_run: requires pre-supplied certificate::"* ]]
}
