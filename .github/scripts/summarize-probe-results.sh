#!/usr/bin/env bash
# Summarize downloaded probe-*.json files for probe-runner-reachability.yml.
# Missing samples (no file) get a table row and fail the job so a partial
# record cannot overwrite a fuller probe-results artifact.
set -euo pipefail
shopt -s nullglob

: "${EXPECTED_SAMPLES:?EXPECTED_SAMPLES is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"

if ! [[ "${EXPECTED_SAMPLES}" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::EXPECTED_SAMPLES must be a positive integer"
  exit 1
fi

# Shown under the table and in the incomplete-record error when any sample is missing.
MISSING_NOTE="Missing samples mean results didn't come back, which is usually a GitHub job/runner hiccup and not an IP block, so re-run all jobs."

# </dev/null: with no sample files, jq slurps an empty list instead of waiting on stdin
FILES=(probes/*.json)

jq -rs --argjson n "${EXPECTED_SAMPLES}" --arg note "${MISSING_NOTE}" '
  (map({key: (.sample | tonumber | tostring), value: .}) | from_entries) as $by
  | [range(1; $n + 1)] as $ids
  | ($ids | map(select($by[tostring] == null))) as $missing
  | ($ids | map($by[tostring] | select(. != null))) as $present
  | "| Sample | Runner IP | gold :6443 | silver :6443 | silver router :443 | API blocked | Router OK while API blocked |",
    "|---|---|---|---|---|---|---|",
    ($ids[] | . as $i | $by["\($i)"] as $s
      | if $s then
          "| \($s.sample) | \($s.ip) | \($s.gold_api) | \($s.silver_api) | \($s.silver_router) | \($s.api_blocked) | \($s.router_ok_while_api_blocked) |"
        else
          "| \($i) | missing | no result / job never ran | - | - | - | - |"
        end),
    "",
    "Samples: \($present | length), missing: \($missing | length), unique IPs: \($present | map(.ip) | unique | length), API blocked: \($present | map(select(.api_blocked)) | length), router OK while API blocked: \($present | map(select(.router_ok_while_api_blocked)) | length)",
    (if ($missing | length) > 0 then "", $note else empty end)
' "${FILES[@]}" < /dev/null | tee -a "${GITHUB_STEP_SUMMARY}"

# One record per run for probe-runner-report.yml (present samples only)
jq -s \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson run_id "${GITHUB_RUN_ID}" \
  --argjson run_attempt "${GITHUB_RUN_ATTEMPT}" \
  '{timestamp: $timestamp, run_id: $run_id, run_attempt: $run_attempt, samples: sort_by(.sample | tonumber)}' \
  "${FILES[@]}" < /dev/null > probe-results.json

TOTAL="$(jq '.samples | length' probe-results.json)"
BLOCKED="$(jq '.samples | map(select(.api_blocked)) | length' probe-results.json)"
if [ "${BLOCKED}" -gt 0 ]; then
  echo "::warning::OpenShift API unreachable from ${BLOCKED} of ${TOTAL} runner sample(s); recorded in the table above and in probe-results"
fi

# A failed or partial re-run (per-sample artifacts expire after a day) must not
# overwrite a fuller record, so stop before the upload unless samples are exactly 1-N
if ! jq -e --argjson n "${EXPECTED_SAMPLES}" \
  '.samples | map(.sample | tonumber) | sort == [range(1; $n + 1)]' probe-results.json > /dev/null; then
  missing="$(jq -r --argjson n "${EXPECTED_SAMPLES}" \
    '[range(1; $n + 1)] - (.samples | map(.sample | tonumber)) | map(tostring) | join(", ")' \
    probe-results.json)"
  msg="Incomplete probe record: expected samples 1-${EXPECTED_SAMPLES}"
  if [ -n "${missing}" ]; then
    msg="${msg}, missing ${missing}"
  fi
  msg="${msg}. Re-run all jobs to regenerate missing or expired samples."
  if [ -n "${missing}" ]; then
    msg="${msg} ${MISSING_NOTE}"
  fi
  echo "::error::${msg}"
  exit 1
fi
