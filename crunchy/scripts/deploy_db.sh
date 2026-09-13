#!/bin/bash

# Catch errors and unset variables
set -euo pipefail

# Remove S3_ENABLED and adjust logic to use S3 inputs if provided
if [ "$#" -lt 4 ]; then
  echo "Usage: $0 <directory> <values_url> <app_name> <release_name> [s3_access_key] [s3_secret_key] [s3_bucket] [s3_endpoint]"
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
# Deploy Database
echo 'Deploying crunchy helm chart'
cd $DIRECTORY

# Download values.yml file
CURL_AUTH_OPTS=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  CURL_AUTH_OPTS=(-H "Authorization: token ${GITHUB_TOKEN}")
fi
curl --fail --location --silent --show-error "${CURL_AUTH_OPTS[@]}" -o ./values.yml "$VALUES_URL"
echo "Downloaded values.yml (current directory: charts/crunchy)"

# Set Helm app name
sed -i "s/^name:.*/name: $APP_NAME/" Chart.yaml
CHART_VERSION=$(yq -r .version Chart.yaml)
# Package, update and deploy the chart
helm package -u .

# if it is not triggered TRIGGERED value is false, check if the chart is already deployed, if not deployed, deploy it else exit 0.
if [ "${TRIGGERED:-false}" != "true" ]; then
  if ! helm status "$RELEASE_NAME" > /dev/null 2>&1; then
    echo "Chart DB $RELEASE_NAME not deployed, deploying now, ignoring triggers."
  else
    echo "Crunchy DB $RELEASE_NAME is already deployed, triggers did not fire, so not upgrading."
    exit 0
  fi
fi

# Build Helm set strings; add non-S3 options first if needed
SET_STRINGS=""
if [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ] && [ -n "$S3_BUCKET" ] && [ -n "$S3_ENDPOINT" ]; then
  SET_STRINGS+=" --set crunchy.pgBackRest.s3.enabled=true \
    --set-string crunchy.pgBackRest.s3.accessKey=$S3_ACCESS_KEY \
    --set-string crunchy.pgBackRest.s3.secretKey=$S3_SECRET_KEY \
    --set-string crunchy.pgBackRest.s3.bucket=$S3_BUCKET \
    --set-string crunchy.pgBackRest.s3.endpoint=$S3_ENDPOINT"
fi

# Execute the Helm command
if [ "${DEBUG_MODE:-false}" = "true" ]; then
  helm upgrade --debug --dry-run --install --wait "$RELEASE_NAME" --values ./values.yml ./$APP_NAME-$CHART_VERSION.tgz $SET_STRINGS
else
  helm upgrade --install --wait "$RELEASE_NAME" --values ./values.yml ./$APP_NAME-$CHART_VERSION.tgz $SET_STRINGS
fi
# Verify successful db deployment; wait retry 10 times with 60 seconds interval
for i in $(seq 1 "$MAX_DB_READY_RETRIES"); do
  # Check if the 'db' instance has at least 1 ready replica
  if oc get PostgresCluster/"$RELEASE_NAME"-crunchy -o json | jq -e '.status.instances[] | select(.name=="db") | .readyReplicas > 0' > /dev/null 2>&1; then
    echo "Crunchy DB instance 'db' is ready."
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
