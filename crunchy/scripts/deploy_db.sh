#!/bin/bash

# Catch errors and unset variables
set -euo pipefail

if [ "$#" -lt 5 ]; then
  echo "Usage: $0 <directory> <values_url|''> <app_name> <release_name> <triggered> [s3_access_key] [s3_secret_key] [s3_bucket] [s3_endpoint]"
  exit 1
fi

DIRECTORY="$1"
VALUES_URL="$2"
APP_NAME="$3"
RELEASE_NAME="$4"
TRIGGERED="$5"
S3_ACCESS_KEY="${6:-}"
S3_SECRET_KEY="${7:-}"
S3_BUCKET="${8:-}"
S3_ENDPOINT="${9:-}"
MAX_DB_READY_RETRIES=90
DB_READY_SLEEP_SECONDS=10
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Validate overrides before any side effects (one Helm arg per line)
OVERRIDE_ARGS=()
while IFS= read -r arg; do
  [ -n "${arg}" ] && OVERRIDE_ARGS+=("${arg}")
done < <(VALUES_URL="${VALUES_URL}" "${SCRIPT_DIR}/resolve_helm_args.sh")

# Standby via action inputs needs S3 (repo2). values_file callers configure S3 themselves.
if [ "${STANDBY_ENABLED:-false}" = "true" ]; then
  if [ -z "${S3_ACCESS_KEY:-}" ] || [ -z "${S3_SECRET_KEY:-}" ] || [ -z "${S3_BUCKET:-}" ] || [ -z "${S3_ENDPOINT:-}" ]; then
    echo "Error: standby_enabled requires s3_access_key, s3_secret_key, s3_bucket and s3_endpoint (standby follows repo2)."
    exit 1
  fi
fi

# Deploy Database
echo 'Deploying crunchy helm chart'
cd "$DIRECTORY"

if [ "${ROUTE_ENABLED:-false}" = "true" ] && [ ! -f templates/route.yaml ]; then
  echo "Error: route_enabled is true, but the chart in '${DIRECTORY}' has no templates/route.yaml."
  exit 1
fi

if [ -n "$VALUES_URL" ]; then
  CURL_AUTH_OPTS=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    CURL_AUTH_OPTS=(-H "Authorization: token ${GITHUB_TOKEN}")
  fi
  curl --fail --location --silent --show-error "${CURL_AUTH_OPTS[@]}" -o ./values.yml "$VALUES_URL"
  echo "Downloaded values.yml (current directory: ${DIRECTORY})"
else
  cp "${SCRIPT_DIR}/../values.yml" ./values.yml
  echo "No values_file provided; using the action's bundled values.yml"
fi
if ! yq -e '.' ./values.yml > /dev/null; then
  echo "Error: values.yml is not valid YAML."
  exit 1
fi

# Effective shutdown: action input or values_file
EFFECTIVE_SHUTDOWN=false
if [ "${SHUTDOWN:-false}" = "true" ]; then
  EFFECTIVE_SHUTDOWN=true
elif [ "$(yq -r '.crunchy.shutdown // false' ./values.yml)" = "true" ]; then
  EFFECTIVE_SHUTDOWN=true
fi

# Set Helm app name
sed -i "s/^name:.*/name: $APP_NAME/" Chart.yaml
CHART_VERSION=$(yq -r .version Chart.yaml)
# Package, update and deploy the chart
helm package -u .

# Current release status; empty when no release exists
HELM_RELEASE_STATUS=""
if STATUS_JSON="$(helm status "$RELEASE_NAME" -o json 2> /dev/null)"; then
  HELM_RELEASE_STATUS="$(jq -r '.info.status' <<< "$STATUS_JSON")"
fi
echo "Helm release '${RELEASE_NAME}' status: '${HELM_RELEASE_STATUS:-<none>}'"

# Triggers did not fire: skip only a healthy (deployed) release; otherwise deploy.
# dry_run never changes the cluster, so it still renders.
if [ "${DRY_RUN:-false}" != "true" ] && [ "${TRIGGERED:-false}" != "true" ]; then
  if [ "$HELM_RELEASE_STATUS" = "deployed" ]; then
    echo "Crunchy DB $RELEASE_NAME is already deployed, triggers did not fire, so not upgrading."
    exit 0
  fi
  echo "Chart DB $RELEASE_NAME is not in a deployed state, deploying now, ignoring triggers."
fi

# Self-heal a release left in a non-deployed state (pending-*, failed, uninstalling),
# which blocks helm upgrade --install. Opt-in: deleting the PostgresCluster also
# deletes the operator-owned PVCs, so the database starts empty.
# Never purge on dry_run.
if [ "${DRY_RUN:-false}" != "true" ] && [ "${SELF_HEAL_STUCK_RELEASES:-false}" = "true" ]; then
  if [ -n "$HELM_RELEASE_STATUS" ] && [ "$HELM_RELEASE_STATUS" != "deployed" ]; then
    echo "Purging release '${RELEASE_NAME}' before reinstall."
    if ! helm uninstall "$RELEASE_NAME" --wait --timeout 2m; then
      echo "helm uninstall did not complete; deleting the release's Helm storage secrets directly."
    fi
    oc delete secret -l "owner=helm,name=${RELEASE_NAME}" --ignore-not-found=true
    oc delete "postgrescluster.postgres-operator.crunchydata.com/${RELEASE_NAME}-crunchy" --ignore-not-found=true --wait=true
  fi
fi

# Quoted Helm arg array (never expand unquoted). Overrides are already validated.
CHART_TGZ="./${APP_NAME}-${CHART_VERSION}.tgz"
HELM_ARGS=()
if [ "${DRY_RUN:-false}" = "true" ]; then
  HELM_ARGS+=(--dry-run=server --hide-secret)
fi
HELM_ARGS+=(--install --wait "$RELEASE_NAME" --values ./values.yml "${CHART_TGZ}")
HELM_ARGS+=("${OVERRIDE_ARGS[@]}")

if [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ] && [ -n "$S3_BUCKET" ] && [ -n "$S3_ENDPOINT" ]; then
  HELM_ARGS+=(--set "crunchy.pgBackRest.s3.enabled=true")
  HELM_ARGS+=(--set-string "crunchy.pgBackRest.s3.accessKey=${S3_ACCESS_KEY}")
  HELM_ARGS+=(--set-string "crunchy.pgBackRest.s3.secretKey=${S3_SECRET_KEY}")
  HELM_ARGS+=(--set-string "crunchy.pgBackRest.s3.bucket=${S3_BUCKET}")
  HELM_ARGS+=(--set-string "crunchy.pgBackRest.s3.endpoint=${S3_ENDPOINT}")
fi

# Optional custom password via --set-file (mode 600 temp); shared with #119 pattern
PASS_FILE=""
cleanup_pass_file() {
  if [ -n "${PASS_FILE}" ] && [ -f "${PASS_FILE}" ]; then
    rm -f "${PASS_FILE}"
  fi
}
trap cleanup_pass_file EXIT

if [ -n "${CUSTOM_PGUSER_PASSWORD:-}" ]; then
  PASS_FILE="$(mktemp)"
  chmod 600 "${PASS_FILE}"
  printf '%s' "${CUSTOM_PGUSER_PASSWORD}" > "${PASS_FILE}"
  HELM_ARGS+=(--set-file "crunchy.pgUser.customPassword=${PASS_FILE}")
fi

helm upgrade "${HELM_ARGS[@]}"

if [ "${DRY_RUN:-false}" = "true" ]; then
  echo "dry_run: helm upgrade --dry-run=server completed; skipping database ready check."
  exit 0
fi

CLUSTER="PostgresCluster/${RELEASE_NAME}-crunchy"

if [ "${EFFECTIVE_SHUTDOWN}" = "true" ]; then
  # Shutdown scales workloads to zero; wait until no ready replicas remain.
  for i in $(seq 1 "$MAX_DB_READY_RETRIES"); do
    if oc get "${CLUSTER}" -o json | jq -e '([.status.instances[].readyReplicas // 0] | add // 0) == 0' > /dev/null 2>&1; then
      echo "Crunchy DB is shut down (no ready replicas)."
      exit 0
    fi
    echo "Attempt $i: Crunchy DB still has ready replicas during shutdown, waiting for $DB_READY_SLEEP_SECONDS seconds"
    sleep "$DB_READY_SLEEP_SECONDS"
  done
  echo "Crunchy DB did not shut down after $MAX_DB_READY_RETRIES attempts."
  exit 1
fi

# Verify successful db deployment
for i in $(seq 1 "$MAX_DB_READY_RETRIES"); do
  if oc get "${CLUSTER}" -o json | jq -e '([.status.instances[].readyReplicas // 0] | add // 0) > 0' > /dev/null 2>&1; then
    echo "Crunchy DB instance is ready."
    exit 0
  fi
  echo "Attempt $i: Crunchy DB is not ready, waiting for $DB_READY_SLEEP_SECONDS seconds"
  sleep "$DB_READY_SLEEP_SECONDS"
done

echo "Crunchy DB did not become ready after $MAX_DB_READY_RETRIES attempts."
exit 1
