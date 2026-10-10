#!/usr/bin/env bats
# oc-runner login: blocked-runner and outage reporting, with curl and oc stubbed (no cluster)

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../oc-runner/scripts/login.sh"
  STUBS="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUBS"
  export SCRIPT STUBS
  export PATH="${STUBS}:${PATH}"
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
  export SERVER_URL=https://api.silver.devops.gov.bc.ca:6443
  export NAMESPACE=abc123-dev
  export TOKEN_INPUT=dummy-token-dummy-token-dummy-token
  export ATTEMPTS=2
  export OC=stable-4.18
  export LOGIN_RETRY_DELAY=0
  # Stub behaviour: one word per /version call (answer, refused or timeout; the last word repeats)
  export STUB_API="answer"
  export STUB_ROUTER=up
  # Token POST: 201, 000 (timeout, curl exit 28) or an HTTP code such as 403
  export STUB_TOKEN=201
  export STUB_STATE="${BATS_TEST_TMPDIR}/version_calls"
  echo 0 > "$STUB_STATE"

  cat > "${STUBS}/curl" <<'STUB'
#!/usr/bin/env bash
url="${*: -1}"
for a in "$@"; do [[ "$a" == https://* ]] && url="$a"; done
case "$url" in
  https://api.ipify.org) echo 203.0.113.7 ;;
  https://console.apps.*) [ "$STUB_ROUTER" = up ] || { echo "curl: (28) Connection timed out" >&2; exit 28; } ;;
  */version)
    n=$(cat "$STUB_STATE"); echo $((n + 1)) > "$STUB_STATE"
    read -ra seq <<< "$STUB_API"
    mode="${seq[$n]:-${seq[-1]}}"
    case "$mode" in
      answer) ;;
      refused) echo "curl: (7) Failed to connect" >&2; exit 7 ;;
      timeout) echo "curl: (28) Connection timed out" >&2; exit 28 ;;
    esac ;;
  */token)
    case "$STUB_TOKEN" in
      000) echo "curl: (28) Connection timed out" >&2; printf '000'; exit 28 ;;
      201) printf '{"status":{"token":"sha256~abc"}}201' ;;
      *) printf '{"kind":"Status"}%s' "$STUB_TOKEN" ;;
    esac ;;
esac
STUB
  cat > "${STUBS}/oc" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  project) echo "$NAMESPACE" ;;
  *) echo "oc $*" ;;
esac
STUB
  chmod +x "${STUBS}/curl" "${STUBS}/oc"
}

run_script() {
  run bash -c 'cd "$BATS_TEST_TMPDIR" && "$SCRIPT" 2>&1'
}

@test "blocked at pre-flight: titled annotation, summary and blocked output" {
  export STUB_API=timeout
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=IP blocked from OpenShift (not a code problem)::This runner's IP (203.0.113.7) is blocked from the OpenShift API (https://api.silver.devops.gov.bc.ca:6443). Re-run this job, and speak with your network administrators if it keeps happening."* ]]
  [[ "$output" != *"Failed to log in"* ]]
  grep -qx 'blocked=true' "$GITHUB_OUTPUT"
  grep -qx 'unreachable=false' "$GITHUB_OUTPUT"
  grep -q '^### IP blocked from OpenShift (not a code problem)$' "$GITHUB_STEP_SUMMARY"
  grep -q 'Runner IP: `203.0.113.7`' "$GITHUB_STEP_SUMMARY"
  grep -q 'Re-run this job' "$GITHUB_STEP_SUMMARY"
}

@test "outage at pre-flight: outage annotation and unreachable output" {
  export STUB_API=refused STUB_ROUTER=down
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=OpenShift unreachable (outage, not a code problem)::Neither the OpenShift API (https://api.silver.devops.gov.bc.ca:6443) nor the silver router answered this runner (IP 203.0.113.7)."* ]]
  [[ "$output" == *"Re-run this job once OpenShift is back."* ]]
  grep -qx 'unreachable=true' "$GITHUB_OUTPUT"
  grep -qx 'blocked=false' "$GITHUB_OUTPUT"
  grep -q '^### OpenShift unreachable (outage, not a code problem)$' "$GITHUB_STEP_SUMMARY"
}

@test "blocked mid-job: blocked message replaces the generic login failure" {
  export STUB_API="answer timeout" STUB_TOKEN=000
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=IP blocked from OpenShift (not a code problem)::"* ]]
  [[ "$output" != *"Failed to log in"* ]]
  [ "$(grep -c '^::error' <<< "$output")" -eq 1 ]
  grep -qx 'blocked=true' "$GITHUB_OUTPUT"
}

@test "token timeout while /version still answers: generic login failure with runner IP" {
  export STUB_API=answer STUB_TOKEN=000
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::Failed to log in to OpenShift after 2 attempts. Runner public IP: 203.0.113.7"* ]]
  [[ "$output" != *"title=IP blocked"* ]]
  grep -qx 'blocked=false' "$GITHUB_OUTPUT"
}

@test "client error fails fast without a blocked report" {
  export STUB_TOKEN=403
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::API request failed with HTTP 403. Failing fast."* ]]
  [ "$(grep -c 'Attempting to acquire token' <<< "$output")" -eq 1 ]
  grep -qx 'blocked=false' "$GITHUB_OUTPUT"
  grep -qx 'unreachable=false' "$GITHUB_OUTPUT"
}

@test "successful login sets both outputs false" {
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"Login successful!"* ]]
  grep -qx 'blocked=false' "$GITHUB_OUTPUT"
  grep -qx 'unreachable=false' "$GITHUB_OUTPUT"
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "unrecognised server falls back to the silver router" {
  export SERVER_URL=https://api.example.test:6443 STUB_API=timeout
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"using the silver router"* ]]
  [[ "$output" == *"title=IP blocked from OpenShift (not a code problem)"* ]]
}
