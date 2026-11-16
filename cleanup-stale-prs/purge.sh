#!/usr/bin/env bash
# Purge stale or closed PR OpenShift deployments (by app label) and/or Crunchy PR users/databases.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_CHANGE_SCRIPT="${USER_CHANGE_SCRIPT:-${SCRIPT_DIR}/../crunchy/scripts/user_change.sh}"

REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-}}"
PREFIX="${PREFIX:-${REPOSITORY#*/}}"
CLEANUP_LABEL="${CLEANUP_LABEL:-true}"
CRUNCHY="${CRUNCHY:-false}"
CRUNCHY_RELEASE_NAME="${CRUNCHY_RELEASE_NAME:-}"
DAYS="${DAYS:-7}"
INCLUDE_OPEN="${INCLUDE_OPEN:-true}"
DRY_RUN="${DRY_RUN:-false}"
TOKEN="${TOKEN:-}"
DEBUG="${DEBUG:-false}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

fail() {
  echo "::error::$1" >&2
  exit 1
}

if [ "${CLEANUP_LABEL}" != "true" ] && [ "${CRUNCHY}" != "true" ]; then
  fail "At least one of cleanup_label or crunchy must be true."
fi
if ! [[ "${DAYS}" =~ ^[1-9][0-9]*$ ]]; then
  fail "Invalid days '${DAYS}': expected a positive integer."
fi
if ! [[ "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  fail "Invalid repository '${REPOSITORY}': expected owner/repo."
fi
if [ -z "${PREFIX}" ]; then
  fail "prefix could not be determined."
fi

NOW_EPOCH="${NOW_EPOCH:-$(date -u +%s)}"
CUTOFF_EPOCH=$(( NOW_EPOCH - DAYS * 86400 ))

if [ "${DEBUG}" = "true" ]; then
  set -x
fi

declare -A PR_PURGE_CACHE=()
declare -A PR_REASON_CACHE=()
declare -A SEEN_LABELS=()
DELETED_LABELS=()
DELETED_CRUNCHY_PRS=()

parse_epoch() {
  local ts="${1:-}"
  [ -n "$ts" ] || return 1
  date -u -d "$ts" +%s 2>/dev/null
}

# Queries GitHub PR state once per PR number and caches the decision.
# Sets global PR_DECISION ("true"|"false") and PR_REASON.
check_pr_purge() {
  local pr="$1"
  local fallback_ts="${2:-}"

  if [ -n "${PR_PURGE_CACHE[$pr]+x}" ]; then
    PR_DECISION="${PR_PURGE_CACHE[$pr]}"
    PR_REASON="${PR_REASON_CACHE[$pr]}"
    return 0
  fi

  local resp_file http_status curl_cfg state updated_at updated_epoch fallback_epoch
  resp_file="$(mktemp)"

  # Never expose TOKEN in ps or set -x trace
  { set +x; } 2>/dev/null
  curl_cfg="$(mktemp)"
  chmod 600 "$curl_cfg"
  {
    printf 'header = "Accept: application/vnd.github+json"\n'
    printf 'header = "X-GitHub-Api-Version: 2022-11-28"\n'
    if [ -n "${TOKEN}" ]; then
      printf 'header = "Authorization: Bearer %s"\n' "${TOKEN}"
    fi
  } > "$curl_cfg"

  http_status="$(curl -sS -K "$curl_cfg" -o "$resp_file" -w '%{http_code}' \
    "${GITHUB_API_URL}/repos/${REPOSITORY}/pulls/${pr}")" || {
    rm -f "$curl_cfg" "$resp_file"
    fail "Failed to query GitHub PR #${pr} for ${REPOSITORY}."
  }
  rm -f "$curl_cfg"
  if [ "${DEBUG}" = "true" ]; then
    set -x
  fi

  case "$http_status" in
    200)
      IFS='|' read -r state updated_at < <(jq -r '[.state // "", .updated_at // ""] | join("|")' "$resp_file")
      rm -f "$resp_file"
      if [ "$state" = "closed" ]; then
        PR_DECISION="true"
        PR_REASON="PR #${pr} is closed"
      elif [ "$state" = "open" ]; then
        if [ "${INCLUDE_OPEN}" != "true" ]; then
          PR_DECISION="false"
          PR_REASON="PR #${pr} is open (include_open=false)"
        elif updated_epoch="$(parse_epoch "$updated_at")" && [ "$updated_epoch" -lt "$CUTOFF_EPOCH" ]; then
          PR_DECISION="true"
          PR_REASON="PR #${pr} is open and inactive since ${updated_at} (>${DAYS}d)"
        else
          PR_DECISION="false"
          PR_REASON="PR #${pr} is open and active (updated ${updated_at})"
        fi
      else
        fail "Unexpected GitHub PR #${pr} state '${state}'."
      fi
      ;;
    404)
      rm -f "$resp_file"
      if fallback_epoch="$(parse_epoch "$fallback_ts")" && [ "$fallback_epoch" -lt "$CUTOFF_EPOCH" ]; then
        PR_DECISION="true"
        PR_REASON="PR #${pr} not found on GitHub; created ${fallback_ts} (>${DAYS}d)"
      else
        PR_DECISION="false"
        PR_REASON="PR #${pr} not found on GitHub; within ${DAYS}d window or unknown age"
      fi
      ;;
    *)
      local body
      body="$(cat "$resp_file" 2>/dev/null || true)"
      rm -f "$resp_file"
      fail "GitHub API returned HTTP ${http_status} for ${REPOSITORY} PR #${pr}: ${body}"
      ;;
  esac

  PR_PURGE_CACHE["$pr"]="$PR_DECISION"
  PR_REASON_CACHE["$pr"]="$PR_REASON"
}

sweep_labels() {
  local deploys_json name app_label created_ts suffix pr
  deploys_json="$(oc get deploy -o json)"

  while IFS='|' read -r name app_label created_ts; do
    [ -n "$name" ] || continue
    [[ "$name" == "${PREFIX}-"* ]] || continue
    suffix="${name#"${PREFIX}-"}"
    if [[ "$suffix" =~ ^([1-9][0-9]*)(-|$) ]]; then
      pr="${BASH_REMATCH[1]}"
    else
      continue
    fi

    check_pr_purge "$pr" "$created_ts"
    if [ "$PR_DECISION" != "true" ]; then
      echo "Keeping deployment ${name}: ${PR_REASON}"
      continue
    fi

    if [ -z "$app_label" ]; then
      fail "Deployment ${name} matches stale PR #${pr} (${PR_REASON}) but has no app label."
    fi

    if [ -n "${SEEN_LABELS[$app_label]+x}" ]; then
      echo "Already processed app=${app_label} (via deployment ${name})"
      continue
    fi
    SEEN_LABELS["$app_label"]=1

    if [ "${DRY_RUN}" = "true" ]; then
      echo "[dry-run] Would delete resources for app=${app_label} (${PR_REASON})"
    else
      echo "Deleting resources for app=${app_label} (${PR_REASON})"
      oc delete all,jobs,cronjobs,cm,pvc,secret,networkpolicy,routes,hpa -l "app=${app_label}" --ignore-not-found
    fi
    DELETED_LABELS+=("$app_label")
  done < <(jq -r '.items[]? | [.metadata.name // "", .metadata.labels.app // "", .metadata.creationTimestamp // ""] | join("|")' <<< "$deploys_json")
}

sweep_crunchy() {
  local repo_name release_name cluster_name cluster_json user_name pr fallback_ts
  repo_name="${REPOSITORY#*/}"
  if [ -n "${CRUNCHY_RELEASE_NAME}" ]; then
    release_name="${CRUNCHY_RELEASE_NAME}"
  else
    release_name="pg-$(printf '%s' "${repo_name}" | md5sum | cut -c 1-8)"
  fi
  cluster_name="${release_name}-crunchy"

  if ! cluster_json="$(oc get "PostgresCluster/${cluster_name}" -o json 2>/dev/null)"; then
    echo "Crunchy PostgresCluster ${cluster_name} not found; skipping Crunchy cleanup."
    return 0
  fi

  while IFS= read -r user_name; do
    [ -n "$user_name" ] || continue
    if [[ "$user_name" =~ ^app-([1-9][0-9]*)$ ]]; then
      pr="${BASH_REMATCH[1]}"
    else
      continue
    fi

    fallback_ts=""
    if [ -z "${PR_PURGE_CACHE[$pr]+x}" ]; then
      fallback_ts="$(oc get secret "${cluster_name}-pguser-app-${pr}" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
    fi

    check_pr_purge "$pr" "$fallback_ts"
    if [ "$PR_DECISION" != "true" ]; then
      echo "Keeping Crunchy user app-${pr} on ${cluster_name}: ${PR_REASON}"
      continue
    fi

    if [ "${DRY_RUN}" = "true" ]; then
      echo "[dry-run] Would remove Crunchy user/database app-${pr} from ${cluster_name} (${PR_REASON})"
    else
      echo "Removing Crunchy user/database app-${pr} from ${cluster_name} (${PR_REASON})"
      "${USER_CHANGE_SCRIPT}" remove "${pr}" "${cluster_name}"
    fi
    DELETED_CRUNCHY_PRS+=("$pr")
  done < <(jq -r '.spec.users[]?.name // empty' <<< "$cluster_json")
}

if [ "${CLEANUP_LABEL}" = "true" ]; then
  sweep_labels
fi

if [ "${CRUNCHY}" = "true" ]; then
  sweep_crunchy
fi

if [ "${#DELETED_LABELS[@]}" -eq 0 ]; then
  deleted_labels_json="[]"
else
  deleted_labels_json="$(jq -cn '$ARGS.positional' --args -- "${DELETED_LABELS[@]}")"
fi

if [ "${#DELETED_CRUNCHY_PRS[@]}" -eq 0 ]; then
  deleted_crunchy_json="[]"
else
  deleted_crunchy_json="$(jq -cn '$ARGS.positional' --args -- "${DELETED_CRUNCHY_PRS[@]}")"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "deleted_labels=${deleted_labels_json}"
    echo "deleted_crunchy_prs=${deleted_crunchy_json}"
  } >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    if [ "${DRY_RUN}" = "true" ]; then
      echo "### Stale PR Cleanup (dry run)"
    else
      echo "### Stale PR Cleanup"
    fi
    echo
    echo "- Prefix: \`${PREFIX}\`"
    echo "- Labels selected: \`${deleted_labels_json}\`"
    echo "- Crunchy PRs selected: \`${deleted_crunchy_json}\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
