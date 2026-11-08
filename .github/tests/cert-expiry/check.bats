#!/usr/bin/env bats
# cert-expiry reads public leaf certificates from local openssl s_server
# instances and reports expiring, expired and unreadable hosts. It prints only
# hosts, dates and day counts, never certificate or key material.

setup_file() {
  D="$BATS_FILE_TMPDIR"
  openssl req -x509 -newkey rsa:2048 -keyout "${D}/key.pem" -out "${D}/ok.pem" -days 365 -nodes -subj "/CN=localhost" 2> /dev/null
  # 90-day certificate with 20 days left: due at a third of its lifetime (30 days)
  openssl req -x509 -key "${D}/key.pem" -out "${D}/soon.pem" -not_before "$(date -u -d '70 days ago' +%Y%m%d%H%M%SZ)" -not_after "$(date -u -d '20 days' +%Y%m%d%H%M%SZ)" -subj "/CN=localhost" 2> /dev/null
  # A certificate for another name, like the router default served to a host with no Route
  openssl req -x509 -key "${D}/key.pem" -out "${D}/other.pem" -days 365 -subj "/CN=example.invalid" 2> /dev/null
  openssl req -x509 -key "${D}/key.pem" -out "${D}/old.pem" -not_before 20200101000000Z -not_after 20210101000000Z -subj "/CN=localhost" 2> /dev/null

  # Free ports: bind, read the number, release
  read -r OK_PORT SOON_PORT OLD_PORT OTHER_PORT CLOSED_PORT < <(python3 -c '
import socket
s=[socket.socket() for _ in range(5)]
for x in s: x.bind(("127.0.0.1",0))
print(*[x.getsockname()[1] for x in s])
for x in s: x.close()')
  export OK_PORT SOON_PORT OLD_PORT OTHER_PORT CLOSED_PORT

  for pair in "ok:${OK_PORT}" "soon:${SOON_PORT}" "old:${OLD_PORT}" "other:${OTHER_PORT}"; do
    openssl s_server -quiet -accept "127.0.0.1:${pair#*:}" -cert "${D}/${pair%%:*}.pem" -key "${D}/key.pem" -www < /dev/null > /dev/null 2>&1 &
    echo "$!" >> "${D}/pids"
  done
  for port in "$OK_PORT" "$SOON_PORT" "$OLD_PORT" "$OTHER_PORT"; do
    for _ in $(seq 50); do
      (exec 3<> "/dev/tcp/127.0.0.1/${port}") 2> /dev/null && break
      sleep 0.1
    done
  done
}

teardown_file() {
  xargs -r kill < "${BATS_FILE_TMPDIR}/pids" 2> /dev/null || true
}

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../cert-expiry/check.sh"
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary"
  : > "$GITHUB_OUTPUT"
  export INPUT_HOSTS="" INPUT_LIFETIME_DIVISOR=3 INPUT_MARGIN_DAYS=0 INPUT_TIMEOUT=5 INPUT_FAIL_ON_FINDINGS=true
}

findings() {
  sed -n 's/^findings=//p' "$GITHUB_OUTPUT"
}

@test "valid certificate passes with no findings" {
  INPUT_HOSTS="localhost:${OK_PORT}" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: localhost:${OK_PORT} expires "* ]]
  [ "$(findings)" = "[]" ]
  grep -qx "checked=1" "$GITHUB_OUTPUT"
  grep -q "| localhost:${OK_PORT} | ok |" "$GITHUB_STEP_SUMMARY"
}

@test "certificate with a third of its lifetime or less left is a finding and fails" {
  INPUT_HOSTS="localhost:${SOON_PORT}" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::localhost:${SOON_PORT} certificate expires"* ]]
  [[ "$output" == *"Fix: "* ]]
  [ "$(findings | jq -r '.[0].status')" = "expiring" ]
  [ "$(findings | jq -r '.[0].days_left')" -ge 19 ]
  [ "$(findings | jq -r '.[0].days_left')" -le 20 ]
  [ "$(findings | jq -r '.[0].lifetime_days')" = "90" ]
  [ -n "$(findings | jq -r '.[0].not_before')" ]
}

@test "lifetime_divisor decides: 20 of 90 days left is fine at 1/100" {
  INPUT_HOSTS="localhost:${SOON_PORT}" INPUT_LIFETIME_DIVISOR=100 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(findings)" = "[]" ]
}

@test "margin_days delays the report: 20 days left is fine at 1/3 minus 15 days, not minus 3" {
  INPUT_HOSTS="localhost:${SOON_PORT}" INPUT_MARGIN_DAYS=15 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(findings)" = "[]" ]
  : > "$GITHUB_OUTPUT"
  INPUT_HOSTS="localhost:${SOON_PORT}" INPUT_MARGIN_DAYS=3 run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(findings | jq -r '.[0].status')" = "expiring" ]
}

@test "a certificate for another name is uncovered even though it is far from expiry" {
  INPUT_HOSTS="localhost:${OTHER_PORT}" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::localhost:${OTHER_PORT} serves a certificate that does not cover it"* ]]
  [ "$(findings | jq -r '.[0].status')" = "uncovered" ]
  [ "$(findings | jq -r '.[0].days_left')" -gt 300 ]
}

@test "expired certificate is a finding" {
  INPUT_HOSTS="localhost:${OLD_PORT}" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(findings | jq -r '.[0].status')" = "expired" ]
  [ "$(findings | jq -r '.[0].not_after')" = "2021-01-01T00:00:00Z" ]
}

@test "host with no TLS answer is unreadable" {
  INPUT_HOSTS="localhost:${CLOSED_PORT}" INPUT_TIMEOUT=2 run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(findings | jq -r '.[0].status')" = "unreadable" ]
}

@test "fail_on_findings false reports findings without failing" {
  INPUT_HOSTS=$'localhost:'"${OK_PORT}"$'\nlocalhost:'"${SOON_PORT}" INPUT_FAIL_ON_FINDINGS=false run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(findings | jq length)" -eq 1 ]
  grep -qx "checked=2" "$GITHUB_OUTPUT"
}

@test "never prints certificate or key material" {
  INPUT_HOSTS=$'localhost:'"${OK_PORT}"$'\nlocalhost:'"${SOON_PORT}"$'\nlocalhost:'"${OLD_PORT}" run bash "$SCRIPT"
  [[ "$output" != *"BEGIN"* ]]
  ! grep -q "BEGIN" "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY"
}

@test "invalid lifetime_divisor and margin_days fail with Fix lines" {
  for d in 0 1 abc 101 "" 1.5; do
    INPUT_HOSTS="localhost:${OK_PORT}" INPUT_LIFETIME_DIVISOR="$d" run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::lifetime_divisor must be a whole number"* ]]
    [[ "$output" == *"Fix: "* ]]
  done
  for m in abc -1 3651 "" 1.5; do
    INPUT_HOSTS="localhost:${OK_PORT}" INPUT_MARGIN_DAYS="$m" run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::margin_days must be a whole number"* ]]
    [[ "$output" == *"Fix: "* ]]
  done
}

@test "invalid timeout and fail_on_findings fail with Fix lines" {
  INPUT_HOSTS="localhost:${OK_PORT}" INPUT_TIMEOUT=0 run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::timeout must be"*"Fix: "* ]]
  INPUT_HOSTS="localhost:${OK_PORT}" INPUT_FAIL_ON_FINDINGS=yes run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::fail_on_findings must be"*"Fix: "* ]]
}

@test "URL, bad hostname and bad port fail with Fix lines" {
  for h in "*" "*.gov.bc.ca" "https://myapp.gov.bc.ca" "myapp.gov.bc.ca/path" "bad_host.gov.bc.ca" "-lead.gov.bc.ca" "myapp.gov.bc.ca:0" "myapp.gov.bc.ca:99999" "myapp.gov.bc.ca:abc"; do
    INPUT_HOSTS="$h" run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::"*"Fix: "* ]]
  done
}

@test "empty host list fails with a Fix line" {
  INPUT_HOSTS=$'  \n# only a comment\n' run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::No hostnames to check."*"Fix: "* ]]
}

@test "multi-line hosts: blank lines and comments skipped, duplicates removed" {
  INPUT_HOSTS=$'localhost:'"${OK_PORT}"$'\n\n# vanity host unset\nLOCALHOST:'"${OK_PORT}"$'\nlocalhost:'"${SOON_PORT}" INPUT_LIFETIME_DIVISOR=100 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx "checked=2" "$GITHUB_OUTPUT"
}

@test "comma or space separated hosts fail with the one-per-line format" {
  for h in "localhost:${OK_PORT}, localhost:${SOON_PORT}" "localhost:${OK_PORT} localhost:${SOON_PORT}"; do
    INPUT_HOSTS="$h" run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"hosts takes one item per line, or a single value."* ]]
  done
}
