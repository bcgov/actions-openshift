#!/usr/bin/env bash
# Unit tests for sysdig-monitor's pre-flight guards (no network).
#
# Every case below exits before apply.sh makes its first API call, so these
# run offline with a dummy token.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY="${SCRIPT_DIR}/../scripts/apply.sh"

passed=0
failed=0

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# run_apply ALERTS_DIR [TOKEN]
# Sets RUN_RC (exit code) and RUN_OUTPUT (combined stdout+stderr).
run_apply() {
    # ${2-...}, not ${2:-...}: an explicitly empty token is the case under test.
    local alerts_dir="$1" token="${2-dummy-token}"
    RUN_RC=0
    RUN_OUTPUT="$(
        SYSDIG_API_TOKEN="${token}" \
        SYSDIG_API_URL="https://app.sysdigcloud.com" \
        OC_NAMESPACE="abc123-prod" \
        APP="unit-test-app" \
        COMPONENTS="frontend,backend" \
        ALERT_DURATION_MINUTES="5" \
        CHANNEL_TEMPLATE="${SCRIPT_DIR}/../templates/channel.json" \
        ALERTS_DIR="${alerts_dir}" \
        bash "${APPLY}" 2>&1
    )" || RUN_RC=$?
}

assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "✓ $name"
        passed=$((passed + 1))
    else
        echo "✗ $name"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        failed=$((failed + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "✓ $name"
        passed=$((passed + 1))
    else
        echo "✗ $name"
        echo "  Expected output to contain: '$needle'"
        echo "  Actual output: '$haystack'"
        failed=$((failed + 1))
    fi
}

test_noop_without_token() {
    run_apply "${TMP_ROOT}/whatever" ""
    assert_eq "${RUN_RC}" "0" "no-op (exit 0) when token is empty"
    assert_contains "${RUN_OUTPUT}" "::warning::SYSDIG_API_TOKEN is empty" \
        "warns about the empty token"
}

test_noop_without_alerts_dir() {
    run_apply "${TMP_ROOT}/does-not-exist"
    assert_eq "${RUN_RC}" "0" "no-op (exit 0) when alerts dir is missing"
    assert_contains "${RUN_OUTPUT}" "::warning::Alerts directory not found" \
        "warns about the missing alerts dir"
}

test_noop_with_empty_alerts_dir() {
    local dir="${TMP_ROOT}/empty"
    mkdir -p "${dir}"
    run_apply "${dir}"
    assert_eq "${RUN_RC}" "0" "no-op (exit 0) when alerts dir has no *.json"
    assert_contains "${RUN_OUTPUT}" "::warning::No *.json alert templates" \
        "warns about the empty alerts dir"
}

test_rejects_unsafe_filename() {
    local dir="${TMP_ROOT}/bad-name"
    mkdir -p "${dir}"
    echo '{}' > "${dir}/CrashLoop Backoff.json"
    run_apply "${dir}"
    assert_eq "${RUN_RC}" "1" "fails on an unsafe alert filename"
    assert_contains "${RUN_OUTPUT}" "::error::Alert filename" \
        "names the offending file"
}

test_rejects_invalid_json() {
    local dir="${TMP_ROOT}/bad-json"
    mkdir -p "${dir}"
    echo 'not json' > "${dir}/crashloop.json"
    run_apply "${dir}"
    assert_eq "${RUN_RC}" "1" "fails on an unparseable alert template"
    assert_contains "${RUN_OUTPUT}" "is not valid JSON" \
        "names the unparseable file"
}

test_channel_template_shape() {
    local template="${SCRIPT_DIR}/../templates/channel.json"
    assert_eq "$(jq -r '.type' "${template}")" "EMAIL" "channel template is an EMAIL channel"
    assert_eq "$(jq -r '.name' "${template}")" "__CHANNEL_NAME__" "channel template name is a placeholder"
    assert_eq "$(jq -r '.options.emailRecipients | length' "${template}")" "0" \
        "channel template ships no recipients"
}

echo "Running sysdig-monitor unit tests..."
echo ""
test_noop_without_token
test_noop_without_alerts_dir
test_noop_with_empty_alerts_dir
test_rejects_unsafe_filename
test_rejects_invalid_json
test_channel_template_shape
echo ""
echo "Passed: ${passed}, Failed: ${failed}"
[[ "${failed}" -eq 0 ]]
