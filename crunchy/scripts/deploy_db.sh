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

# Validate overrides before any side effects
OVERRIDE_ARGS="$(VALUES_URL="${VALUES_URL}" "${SCRIPT_DIR}/resolve_helm_args.sh")"

# Deploy Database
echo 'Deploying crunchy helm chart'
cd "$DIRECTORY"

if [ "${ROUTE_ENABLED:-false}" = "true" ] && [ ! -f templates/route.yaml ]; then
  echo "Error: route_enabled is true, but the chart in '${DIRECTORY}' has no templates/route.yaml."
  exit 1
fi

if [ -n "$VALUES_URL" ]; then
  # Download values.yml file
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

# Build Helm set strings: overrides, then S3 options if provided
SET_STRINGS="${OVERRIDE_ARGS}"
if [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ] && [ -n "$S3_BUCKET" ] && [ -n "$S3_ENDPOINT" ]; then
  SET_STRINGS+=" --set crunchy.pgBackRest.s3.enabled=true \
    --set-string crunchy.pgBackRest.s3.accessKey=$S3_ACCESS_KEY \
    --set-string crunchy.pgBackRest.s3.secretKey=$S3_SECRET_KEY \
    --set-string crunchy.pgBackRest.s3.bucket=$S3_BUCKET \
    --set-string crunchy.pgBackRest.s3.endpoint=$S3_ENDPOINT"
fi

# Execute the Helm command. dry_run validates against the API and stops
# before the ready check, which would fail because nothing was applied.
# --dry-run=server submits the chart to the API. --hide-secret omits Secret
# bodies from the output. --debug is not used: it prints user-supplied values.
if [ "${DRY_RUN:-false}" = "true" ]; then
  helm upgrade --dry-run=server --hide-secret --install "$RELEASE_NAME" --values ./values.yml ./$APP_NAME-$CHART_VERSION.tgz $SET_STRINGS
  echo "dry_run: helm upgrade --dry-run=server completed; skipping database ready check."
  exit 0
fi
helm upgrade --install --wait "$RELEASE_NAME" --values ./values.yml ./$APP_NAME-$CHART_VERSION.tgz $SET_STRINGS
# Verify successful db deployment; wait retry 10 times with 60 seconds interval
for i in $(seq 1 "$MAX_DB_READY_RETRIES"); do
  # Check if any database instance has at least 1 ready replica
  if oc get PostgresCluster/"$RELEASE_NAME"-crunchy -o json | jq -e '([.status.instances[].readyReplicas // 0] | add // 0) > 0' > /dev/null 2>&1; then
    echo "Crunchy DB instance is ready."
    READY=true
    exit 0
  else
    echo "Attempt $i: Crunchy DB is not ready, waiting for $DB_READY_SLEEP_SECONDS seconds"
    sleep $DB_READY_SLEEP_SECONDS
  fi
done

# Landing here means there's a problem
echo "Crunchy DB did not become ready after $MAX_DB_READY_RETRIES attempts."
exit 1
