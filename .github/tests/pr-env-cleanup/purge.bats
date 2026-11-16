#!/usr/bin/env bats
# Unit tests for pr-env-cleanup/purge.sh (stubbed oc and curl)

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../pr-env-cleanup/purge.sh"
  D="${BATS_TEST_TMPDIR}"
  mkdir -p "${D}/bin"

  export OC_DELETE_LOG="${D}/oc-delete.log"
  export OC_GET_LOG="${D}/oc-get.log"
  export USER_CHANGE_LOG="${D}/user-change.log"
  export CURL_LOG="${D}/curl.log"
  export GITHUB_OUTPUT="${D}/github_output"
  export GITHUB_STEP_SUMMARY="${D}/summary"
  : > "${OC_DELETE_LOG}"
  : > "${OC_GET_LOG}"
  : > "${USER_CHANGE_LOG}"
  : > "${CURL_LOG}"
  : > "${GITHUB_OUTPUT}"
  : > "${GITHUB_STEP_SUMMARY}"

  # Fixed "now": 2026-11-16T00:00:00Z (epoch 1794787200); 7d cutoff = 2026-11-09T00:00:00Z
  export NOW_EPOCH=1794787200
  export DEPLOYS_JSON="${D}/deploys.json"
  export CLUSTER_JSON="${D}/cluster.json"
  export PR_RESPONSES="${D}/prs"
  mkdir -p "${PR_RESPONSES}"

  cat > "${DEPLOYS_JSON}" << 'JSON'
{"items":[]}
JSON

  cat > "${D}/bin/oc" << 'STUB'
#!/bin/bash
set -euo pipefail
case "${1:-}" in
  get)
    printf '%s\n' "$*" >> "${OC_GET_LOG}"
    case "${2:-}" in
      deploy)
        cat "${DEPLOYS_JSON}"
        ;;
      PostgresCluster/*)
        if [ -f "${CLUSTER_JSON}" ]; then
          cat "${CLUSTER_JSON}"
        else
          echo "${CLUSTER_ERROR_MSG:-Error from server (NotFound)}" >&2
          exit 1
        fi
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  delete)
    printf '%s\n' "$*" >> "${OC_DELETE_LOG}"
    ;;
  *)
    echo "unexpected oc subcommand: $*" >&2
    exit 1
    ;;
esac
STUB

  cat > "${D}/bin/curl" << 'STUB'
#!/bin/bash
set -euo pipefail
out=""
url=""
cfg=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -K) cfg="$(cat "$2")"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -w) shift 2 ;;
    -sS|-s|-S) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s | %s\n' "$url" "${cfg//$'\n'/; }" >> "${CURL_LOG}"
if [[ "$url" == *"/pulls?"* ]]; then
  code="${PULLS_LIST_CODE:-200}"
  printf '[]' > "$out"
  printf '%s' "$code"
  exit 0
fi
pr="${url##*/}"
if [ -f "${PR_RESPONSES}/${pr}.code" ]; then
  code="$(cat "${PR_RESPONSES}/${pr}.code")"
  cp "${PR_RESPONSES}/${pr}.body" "$out"
  printf '%s' "$code"
else
  printf '{"message":"Not Found"}' > "$out"
  printf '404'
fi
STUB

  cat > "${D}/user_change_stub.sh" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${USER_CHANGE_LOG}"
STUB

  chmod +x "${D}/bin/oc" "${D}/bin/curl" "${D}/user_change_stub.sh"
  export USER_CHANGE_SCRIPT="${D}/user_change_stub.sh"
}

set_pr() {
  local pr="$1" state="$2" updated_at="$3" code="${4:-200}"
  printf '%s' "$code" > "${PR_RESPONSES}/${pr}.code"
  if [ "$code" = "200" ]; then
    printf '{"state":"%s","updated_at":"%s"}' "$state" "$updated_at" > "${PR_RESPONSES}/${pr}.body"
  else
    printf '{"message":"error %s"}' "$code" > "${PR_RESPONSES}/${pr}.body"
  fi
}

run_purge() {
  run env \
    PATH="${D}/bin:${PATH}" \
    REPOSITORY="${REPOSITORY:-bcgov/quickstart-openshift}" \
    PREFIX="${PREFIX-quickstart-openshift}" \
    CLEANUP_LABEL="${CLEANUP_LABEL:-true}" \
    CRUNCHY="${CRUNCHY:-false}" \
    CRUNCHY_RELEASE_NAME="${CRUNCHY_RELEASE_NAME:-}" \
    DAYS="${DAYS:-7}" \
    INCLUDE_OPEN="${INCLUDE_OPEN:-true}" \
    DRY_RUN="${DRY_RUN:-false}" \
    TOKEN="${TOKEN:-secret-token-value}" \
    DEBUG="${DEBUG:-false}" \
    bash "${SCRIPT}"
}

@test "deletes closed and inactive open PRs, keeps active open PR despite old creationTimestamp" {
  cat > "${DEPLOYS_JSON}" << 'JSON'
{
  "items": [
    {"metadata": {"name": "quickstart-openshift-10-backend", "labels": {"app": "quickstart-openshift-10"}, "creationTimestamp": "2026-11-15T00:00:00Z"}},
    {"metadata": {"name": "quickstart-openshift-10-frontend", "labels": {"app": "quickstart-openshift-10"}, "creationTimestamp": "2026-11-15T00:00:00Z"}},
    {"metadata": {"name": "quickstart-openshift-11-backend", "labels": {"app": "quickstart-openshift-11"}, "creationTimestamp": "2026-10-01T00:00:00Z"}},
    {"metadata": {"name": "quickstart-openshift-12-backend", "labels": {"app": "quickstart-openshift-12"}, "creationTimestamp": "2026-10-01T00:00:00Z"}},
    {"metadata": {"name": "other-quickstart-openshift-10-backend", "labels": {"app": "other-10"}, "creationTimestamp": "2026-10-01T00:00:00Z"}}
  ]
}
JSON
  set_pr 10 closed "2026-11-15T00:00:00Z"
  set_pr 11 open "2026-11-14T00:00:00Z"
  set_pr 12 open "2026-11-01T00:00:00Z"

  run_purge
  [ "$status" -eq 0 ]

  # PR 10 (closed) deleted once even with two deployments; PR 12 (inactive) deleted; PR 11 (active) & unanchored other-* kept
  [ "$(wc -l < "${OC_DELETE_LOG}")" -eq 2 ]
  grep -qxF 'delete all,jobs,cronjobs,cm,pvc,secret,networkpolicy,routes,hpa -l app=quickstart-openshift-10 --ignore-not-found' "${OC_DELETE_LOG}"
  grep -qxF 'delete all,jobs,cronjobs,cm,pvc,secret,networkpolicy,routes,hpa -l app=quickstart-openshift-12 --ignore-not-found' "${OC_DELETE_LOG}"
  grep -qxF 'deleted_labels=["quickstart-openshift-10","quickstart-openshift-12"]' "${GITHUB_OUTPUT}"
  grep -qxF 'deleted_crunchy_prs=[]' "${GITHUB_OUTPUT}"
}

@test "include_open=false skips inactive open PRs and deletes closed PRs" {
  cat > "${DEPLOYS_JSON}" << 'JSON'
{
  "items": [
    {"metadata": {"name": "quickstart-openshift-10-backend", "labels": {"app": "quickstart-openshift-10"}, "creationTimestamp": "2026-10-01T00:00:00Z"}},
    {"metadata": {"name": "quickstart-openshift-12-backend", "labels": {"app": "quickstart-openshift-12"}, "creationTimestamp": "2026-10-01T00:00:00Z"}}
  ]
}
JSON
  set_pr 10 closed "2026-11-15T00:00:00Z"
  set_pr 12 open "2026-10-01T00:00:00Z"

  INCLUDE_OPEN=false run_purge
  [ "$status" -eq 0 ]
  [ "$(wc -l < "${OC_DELETE_LOG}")" -eq 1 ]
  grep -qxF 'delete all,jobs,cronjobs,cm,pvc,secret,networkpolicy,routes,hpa -l app=quickstart-openshift-10 --ignore-not-found' "${OC_DELETE_LOG}"
}

@test "prefix override supports custom labels (nr-fom -> fom) and multi-label deployments" {
  cat > "${DEPLOYS_JSON}" << 'JSON'
{
  "items": [
    {"metadata": {"name": "fom-42-api", "labels": {"app": "fom-42"}, "creationTimestamp": "2026-11-15T00:00:00Z"}},
    {"metadata": {"name": "fom-42-admin", "labels": {"app": "fom-42"}, "creationTimestamp": "2026-11-15T00:00:00Z"}},
    {"metadata": {"name": "fom-43-hybrid", "labels": {"app": "fom-43-hybrid"}, "creationTimestamp": "2026-11-15T00:00:00Z"}},
    {"metadata": {"name": "fom-43-postgres", "labels": {"app": "fom-43-postgres"}, "creationTimestamp": "2026-11-15T00:00:00Z"}},
    {"metadata": {"name": "fom-test", "labels": {"app": "fom-test"}, "creationTimestamp": "2026-10-01T00:00:00Z"}},
    {"metadata": {"name": "nr-fom-42-api", "labels": {"app": "nr-fom-42"}, "creationTimestamp": "2026-10-01T00:00:00Z"}}
  ]
}
JSON
  set_pr 42 closed "2026-11-15T00:00:00Z"
  set_pr 43 closed "2026-11-15T00:00:00Z"

  REPOSITORY="bcgov/nr-fom" PREFIX="fom" run_purge
  [ "$status" -eq 0 ]
  [ "$(wc -l < "${OC_DELETE_LOG}")" -eq 3 ]
  grep -qxF 'delete all,jobs,cronjobs,cm,pvc,secret,networkpolicy,routes,hpa -l app=fom-42 --ignore-not-found' "${OC_DELETE_LOG}"
  grep -qxF 'delete all,jobs,cronjobs,cm,pvc,secret,networkpolicy,routes,hpa -l app=fom-43-hybrid --ignore-not-found' "${OC_DELETE_LOG}"
  grep -qxF 'delete all,jobs,cronjobs,cm,pvc,secret,networkpolicy,routes,hpa -l app=fom-43-postgres --ignore-not-found' "${OC_DELETE_LOG}"
  # GitHub PR lookup still targeted bcgov/nr-fom, not bcgov/fom
  grep -q 'repos/bcgov/nr-fom/pulls/42' "${CURL_LOG}"
}

@test "404 PR fails closed when repo is readable and fails fast when pulls endpoint is unreadable" {
  cat > "${DEPLOYS_JSON}" << 'JSON'
{
  "items": [
    {"metadata": {"name": "quickstart-openshift-900-backend", "labels": {"app": "quickstart-openshift-900"}, "creationTimestamp": "2026-10-01T00:00:00Z"}}
  ]
}
JSON

  # Readable repo, genuinely nonexistent PR -> fail closed (nothing deleted)
  PULLS_LIST_CODE=200 run_purge
  [ "$status" -eq 0 ]
  [ ! -s "${OC_DELETE_LOG}" ]
  [[ "$output" == *"skipping (fail closed)"* ]]

  # Unreadable repo/pulls (e.g. private repo without pull-requests: read) -> fail fast
  PULLS_LIST_CODE=404 run_purge
  [ "$status" -eq 1 ]
  [ ! -s "${OC_DELETE_LOG}" ]
  [[ "$output" == *"Cannot read pull requests"* ]]
}

@test "crunchy sweep removes closed/stale PR users, caches PR lookups, and skips non-PR users" {
  expected_hash="$(printf '%s' "quickstart-openshift" | md5sum | cut -c 1-8)"
  expected_cluster="pg-${expected_hash}-crunchy"

  cat > "${DEPLOYS_JSON}" << 'JSON'
{
  "items": [
    {"metadata": {"name": "quickstart-openshift-10-backend", "labels": {"app": "quickstart-openshift-10"}, "creationTimestamp": "2026-11-15T00:00:00Z"}}
  ]
}
JSON
  cat > "${CLUSTER_JSON}" << 'JSON'
{
  "spec": {
    "users": [
      {"name": "app", "databases": ["app"]},
      {"name": "postgres", "databases": ["postgres"]},
      {"name": "app-10", "databases": ["app-10"]},
      {"name": "app-11", "databases": ["app-11"]},
      {"name": "app-12", "databases": ["app-12"]}
    ]
  }
}
JSON
  set_pr 10 closed "2026-11-15T00:00:00Z"
  set_pr 11 open "2026-11-14T00:00:00Z"
  set_pr 12 open "2026-11-01T00:00:00Z"

  CRUNCHY=true run_purge
  [ "$status" -eq 0 ]

  [ "$(wc -l < "${USER_CHANGE_LOG}")" -eq 2 ]
  grep -qxF "remove 10 ${expected_cluster}" "${USER_CHANGE_LOG}"
  grep -qxF "remove 12 ${expected_cluster}" "${USER_CHANGE_LOG}"
  grep -qxF 'deleted_crunchy_prs=["10","12"]' "${GITHUB_OUTPUT}"

  # PR 10 was seen in both Deployments and Crunchy, but GitHub API was queried only once
  [ "$(grep -c 'pulls/10 ' "${CURL_LOG}")" -eq 1 ]
}

@test "crunchy_release_name overrides default hashed cluster name and missing cluster is non-fatal" {
  cat > "${CLUSTER_JSON}" << 'JSON'
{
  "spec": {
    "users": [
      {"name": "app-5", "databases": ["app-5"]}
    ]
  }
}
JSON
  set_pr 5 closed "2026-11-15T00:00:00Z"

  CLEANUP_LABEL=false CRUNCHY=true CRUNCHY_RELEASE_NAME="custom-pg" run_purge
  [ "$status" -eq 0 ]
  grep -qxF "remove 5 custom-pg-crunchy" "${USER_CHANGE_LOG}"
  ! grep -q 'oc get deploy' "${OC_GET_LOG}"

  rm -f "${CLUSTER_JSON}"
  : > "${USER_CHANGE_LOG}"
  CLEANUP_LABEL=false CRUNCHY=true CRUNCHY_RELEASE_NAME="missing-pg" run_purge
  [ "$status" -eq 0 ]
  [ ! -s "${USER_CHANGE_LOG}" ]

  # RBAC / outage errors on PostgresCluster must fail fast rather than silently skip
  CLUSTER_ERROR_MSG="Error from server (Forbidden): postgresclusters is forbidden" \
    CLEANUP_LABEL=false CRUNCHY=true CRUNCHY_RELEASE_NAME="forbidden-pg" run_purge
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to read Crunchy PostgresCluster forbidden-pg-crunchy"* ]]
}

@test "dry_run selects targets without deleting OpenShift resources or Crunchy users" {
  cat > "${DEPLOYS_JSON}" << 'JSON'
{
  "items": [
    {"metadata": {"name": "quickstart-openshift-10-backend", "labels": {"app": "quickstart-openshift-10"}, "creationTimestamp": "2026-11-15T00:00:00Z"}}
  ]
}
JSON
  cat > "${CLUSTER_JSON}" << 'JSON'
{
  "spec": {
    "users": [
      {"name": "app-10", "databases": ["app-10"]}
    ]
  }
}
JSON
  set_pr 10 closed "2026-11-15T00:00:00Z"

  CRUNCHY=true DRY_RUN=true run_purge
  [ "$status" -eq 0 ]
  [ ! -s "${OC_DELETE_LOG}" ]
  [ ! -s "${USER_CHANGE_LOG}" ]
  [[ "$output" == *"[dry-run] Would delete resources for app=quickstart-openshift-10"* ]]
  [[ "$output" == *"[dry-run] Would remove Crunchy user/database app-10"* ]]
  grep -qxF 'deleted_labels=["quickstart-openshift-10"]' "${GITHUB_OUTPUT}"
  grep -qxF 'deleted_crunchy_prs=["10"]' "${GITHUB_OUTPUT}"
}

@test "missing app label on stale deployment fails fast" {
  cat > "${DEPLOYS_JSON}" << 'JSON'
{
  "items": [
    {"metadata": {"name": "quickstart-openshift-10-backend", "labels": {}, "creationTimestamp": "2026-11-15T00:00:00Z"}}
  ]
}
JSON
  set_pr 10 closed "2026-11-15T00:00:00Z"

  run_purge
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no app label"* ]]
}

@test "GitHub API error fails fast without deleting" {
  cat > "${DEPLOYS_JSON}" << 'JSON'
{
  "items": [
    {"metadata": {"name": "quickstart-openshift-10-backend", "labels": {"app": "quickstart-openshift-10"}, "creationTimestamp": "2026-10-01T00:00:00Z"}}
  ]
}
JSON
  set_pr 10 open "2026-10-01T00:00:00Z" 502

  run_purge
  [ "$status" -eq 1 ]
  [ ! -s "${OC_DELETE_LOG}" ]
  [[ "$output" == *"HTTP 502"* ]]
}

@test "debug mode does not leak TOKEN in xtrace output" {
  cat > "${DEPLOYS_JSON}" << 'JSON'
{
  "items": [
    {"metadata": {"name": "quickstart-openshift-10-backend", "labels": {"app": "quickstart-openshift-10"}, "creationTimestamp": "2026-11-15T00:00:00Z"}}
  ]
}
JSON
  set_pr 10 closed "2026-11-15T00:00:00Z"

  TOKEN="super-secret-leak-canary-999" DEBUG=true run_purge
  [ "$status" -eq 0 ]
  [[ "$output" != *"super-secret-leak-canary-999"* ]]
}

@test "invalid configuration fails fast" {
  CLEANUP_LABEL=false CRUNCHY=false run_purge
  [ "$status" -eq 1 ]

  DAYS=0 run_purge
  [ "$status" -eq 1 ]

  REPOSITORY="not-a-repo" run_purge
  [ "$status" -eq 1 ]
}
