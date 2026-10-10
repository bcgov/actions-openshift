#!/usr/bin/env bats
# cert-expiry reads public leaf certificates from local openssl s_server
# instances and reports expiring, expired and unreadable hosts. It prints only
# hosts, dates and day counts, never certificate or key material.

setup_file() {
  D="$BATS_FILE_TMPDIR"
  openssl req -x509 -newkey rsa:2048 -keyout "${D}/key.pem" -out "${D}/ok.pem" -days 365 -nodes -subj "/CN=localhost" 2> /dev/null
  openssl req -x509 -key "${D}/key.pem" -out "${D}/soon.pem" -days 5 -subj "/CN=localhost" 2> /dev/null
  openssl req -x509 -key "${D}/key.pem" -out "${D}/old.pem" -not_before 20200101000000Z -not_after 20210101000000Z -subj "/CN=localhost" 2> /dev/null

  # Free ports: bind, read the number, release
  read -r OK_PORT SOON_PORT OLD_PORT CLOSED_PORT < <(python3 -c '
import socket
s=[socket.socket() for _ in range(4)]
for x in s: x.bind(("127.0.0.1",0))
print(*[x.getsockname()[1] for x in s])
for x in s: x.close()')
  export OK_PORT SOON_PORT OLD_PORT CLOSED_PORT

  for pair in "ok:${OK_PORT}" "soon:${SOON_PORT}" "old:${OLD_PORT}"; do
    openssl s_server -quiet -accept "127.0.0.1:${pair#*:}" -cert "${D}/${pair%%:*}.pem" -key "${D}/key.pem" -www < /dev/null > /dev/null 2>&1 &
    echo "$!" >> "${D}/pids"
  done
  for port in "$OK_PORT" "$SOON_PORT" "$OLD_PORT"; do
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
  export INPUT_HOSTS="" INPUT_HOSTS_FILE="" INPUT_DAYS=30 INPUT_TIMEOUT=5 INPUT_FAIL_ON_FINDINGS=true
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

@test "certificate expiring within days is a finding and fails" {
  INPUT_HOSTS="localhost:${SOON_PORT}" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::localhost:${SOON_PORT} certificate expires"* ]]
  [[ "$output" == *"Fix: "* ]]
  [ "$(findings | jq -r '.[0].status')" = "expiring" ]
  [ "$(findings | jq -r '.[0].days_left')" -le 5 ]
}

@test "days threshold decides: 5-day certificate is fine with days: 1" {
  INPUT_HOSTS="localhost:${SOON_PORT}" INPUT_DAYS=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(findings)" = "[]" ]
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
  INPUT_HOSTS="localhost:${OK_PORT} localhost:${SOON_PORT}" INPUT_FAIL_ON_FINDINGS=false run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(findings | jq length)" -eq 1 ]
  grep -qx "checked=2" "$GITHUB_OUTPUT"
}

@test "hosts_file: comments skipped, entries de-duplicated, combined with hosts" {
  printf '# routes\nlocalhost:%s  # prod\n\nLOCALHOST:%s,localhost:%s\n' "$OK_PORT" "$OK_PORT" "$SOON_PORT" > "${BATS_TEST_TMPDIR}/hosts.txt"
  INPUT_HOSTS="localhost:${OK_PORT}" INPUT_HOSTS_FILE="${BATS_TEST_TMPDIR}/hosts.txt" INPUT_DAYS=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx "checked=2" "$GITHUB_OUTPUT"
}

@test "never prints certificate or key material" {
  INPUT_HOSTS="localhost:${OK_PORT} localhost:${SOON_PORT} localhost:${OLD_PORT}" run bash "$SCRIPT"
  [[ "$output" != *"BEGIN"* ]]
  ! grep -q "BEGIN" "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY"
}

@test "invalid days fails with a Fix line" {
  for d in 0 abc 3651 "" 1.5; do
    INPUT_HOSTS="localhost:${OK_PORT}" INPUT_DAYS="$d" run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::days must be a whole number"* ]]
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
  for h in "https://myapp.gov.bc.ca" "myapp.gov.bc.ca/path" "bad_host.gov.bc.ca" "-lead.gov.bc.ca" "myapp.gov.bc.ca:0" "myapp.gov.bc.ca:99999" "myapp.gov.bc.ca:abc"; do
    INPUT_HOSTS="$h" run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::"*"Fix: "* ]]
  done
}

@test "empty list and missing hosts_file fail with Fix lines" {
  INPUT_HOSTS=$'  \n# only a comment\n' run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::No hostnames to check."*"Fix: "* ]]
  INPUT_HOSTS_FILE="${BATS_TEST_TMPDIR}/missing.txt" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::hosts_file"*"Fix: "* ]]
}
