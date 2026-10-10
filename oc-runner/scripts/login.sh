#!/usr/bin/env bash
# oc-runner login: input gate, API pre-flight, oc install and service-account token login.
# Env: SERVER_URL, NAMESPACE, TOKEN_INPUT, ATTEMPTS, OC (mirror channel, e.g. stable-4.18).
# Writes blocked=true|false and unreachable=true|false to $GITHUB_OUTPUT.
# A runner whose IP is blocked from the API, or an API and router that both stop answering,
# is reported as a titled annotation and a step summary, so the check shows it is not a code problem.

set -eo pipefail

GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
BLOCKED_TITLE="IP blocked from OpenShift (not a code problem)"
UNREACHABLE_TITLE="OpenShift unreachable (outage, not a code problem)"

{
  echo "blocked=false"
  echo "unreachable=false"
} >> "$GITHUB_OUTPUT"

# Input validation gate
if [ -z "${SERVER_URL:-}" ] || [[ ! "${SERVER_URL}" =~ ^https:// ]]; then
  echo "::error::Invalid or missing oc_server. Must be https://"
  exit 1
fi
if [ -z "${NAMESPACE:-}" ]; then
  echo "::error::Missing oc_namespace."
  exit 1
fi
if [ -z "${TOKEN_INPUT:-}" ]; then
  echo "::error::Missing oc_token."
  exit 1
fi
if ! [[ "${ATTEMPTS:-}" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::Invalid login_attempts: '${ATTEMPTS:-}'. Must be a positive integer."
  exit 1
fi
# At most one retry: a blocked runner IP stays blocked, so more attempts only burn minutes
if [ "${ATTEMPTS}" -gt 2 ]; then
  echo "::notice::login_attempts=${ATTEMPTS} capped at 2 (one retry)"
  ATTEMPTS=2
fi

runner_ip() {
  curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown (lookup failed)"
}

# Unauthenticated GET of /version. Any HTTP status (even 401/403) means the API answered.
# Sets API_RC (curl exit code) and API_ERR.
probe_api() {
  API_RC=0
  API_ERR=$(curl -sS -4 -o /dev/null --connect-timeout 10 --max-time 10 "${SERVER_URL}/version" 2>&1) || API_RC=$?
}

# The API did not answer (connection refused or timed out). Probe the same cluster's router
# to tell a blocked runner IP from an outage, report it, set the outputs and exit 1.
report_no_api() {
  local ip cluster msg
  ip=$(runner_ip)
  # Router for the same cluster: api.<cluster>.devops.gov.bc.ca -> console.apps.<cluster>.devops.gov.bc.ca
  if [[ "${SERVER_URL}" =~ ^https://api\.([a-z0-9-]+)\.devops\.gov\.bc\.ca(:[0-9]+)?/?$ ]]; then
    cluster="${BASH_REMATCH[1]}"
  else
    cluster=silver
    echo "::notice::Could not derive the cluster from ${SERVER_URL}; using the silver router for the reachability check"
  fi
  if curl -sS -4 -o /dev/null --connect-timeout 10 --max-time 10 "https://console.apps.${cluster}.devops.gov.bc.ca/" 2>/dev/null; then
    msg="This runner's IP (${ip}) is blocked from the OpenShift API (${SERVER_URL}). Re-run this job, and speak with your network administrators if it keeps happening."
    echo "::error title=${BLOCKED_TITLE}::${msg}"
    echo "blocked=true" >> "$GITHUB_OUTPUT"
    # shellcheck disable=SC2016 # backticks are Markdown, not command substitution
    printf '### %s\n\n%s\n\n- Runner IP: `%s`\n- API: `%s`\n- The %s router answered, so the cluster is up\n' \
      "${BLOCKED_TITLE}" "${msg}" "${ip}" "${SERVER_URL}" "${cluster}" >> "$GITHUB_STEP_SUMMARY"
  else
    msg="Neither the OpenShift API (${SERVER_URL}) nor the ${cluster} router answered this runner (IP ${ip}). OpenShift or the network looks down. Re-run this job once OpenShift is back."
    echo "::error title=${UNREACHABLE_TITLE}::${msg}"
    echo "unreachable=true" >> "$GITHUB_OUTPUT"
    # shellcheck disable=SC2016 # backticks are Markdown, not command substitution
    printf '### %s\n\n%s\n\n- Runner IP: `%s`\n- API: `%s`\n- Next step: re-run the job once OpenShift is back\n' \
      "${UNREACHABLE_TITLE}" "${msg}" "${ip}" "${SERVER_URL}" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
}

# Pre-flight, before oc install, login or any commands
probe_api
if [ "${API_RC}" -eq 7 ] || [ "${API_RC}" -eq 28 ]; then
  echo "Pre-flight: ${API_ERR}"
  report_no_api
elif [ "${API_RC}" -ne 0 ]; then
  echo "::error::Pre-flight request to ${SERVER_URL}/version failed (curl exit ${API_RC}): ${API_ERR}"
  exit 1
fi

# Install CLI Tool (into the working directory, /usr/local/bin in the action)
if ! command -v oc &>/dev/null; then
  URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OC}/openshift-client-linux.tar.gz"
  echo "Downloading OpenShift CLI from ${URL}..."

  # Download the archive with timeout limits
  if ! wget --timeout=15 --tries=3 "${URL}" -qO oc.tar.gz; then
    echo "Error: Failed to download OpenShift CLI"
    exit 1
  fi

  # Extract the oc binary
  if ! tar -xzf oc.tar.gz oc; then
    echo "Error: Failed to extract oc binary"
    rm -f oc.tar.gz
    exit 1
  fi
  rm -f oc.tar.gz
fi

# OpenShift login with smart retry
DELAY="${LOGIN_RETRY_DELAY:-2}"
SA_TOKEN_URL="${SERVER_URL}/api/v1/namespaces/${NAMESPACE}/serviceaccounts/pipeline/token"

attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
  echo "Attempting to acquire token (Attempt $attempt/$ATTEMPTS)..."

  # Fetch token response with HTTP code directly to memory
  ERR_FILE=$(mktemp)
  CURL_RC=0
  RESPONSE=$(curl -sS -4 --connect-timeout 10 --max-time 30 -w "%{http_code}" -X POST "${SA_TOKEN_URL}" \
    --header "Authorization: Bearer ${TOKEN_INPUT}" \
    --header "Content-Type: application/json; charset=utf-8" \
    --data '{"spec": {"expirationSeconds": 1500 }}' 2>"$ERR_FILE") || CURL_RC=$?
  CURL_ERR=$(cat "$ERR_FILE")
  rm -f "$ERR_FILE"

  # Extract HTTP code and response body in memory
  HTTP_CODE="000"
  BODY=""
  if [ ${#RESPONSE} -ge 3 ]; then
    HTTP_CODE="${RESPONSE: -3}"
    BODY="${RESPONSE:0:${#RESPONSE}-3}"
  fi

  # Success path: try to log in
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    TOKEN=$(echo "$BODY" | jq -r '.status.token' 2>/dev/null || true)
    if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
      echo "Error: Failed to parse token from response."
    elif OC_OUT=$(oc login --server="${SERVER_URL}" --token="${TOKEN}" 2>&1); then
      echo "Login successful!"
      break
    else
      echo "Token acquired, but 'oc login' failed. Error: $OC_OUT"
    fi
  # Retry paths: timeouts (000), request timeouts (408), rate limits (429), or server errors (5xx)
  elif [ "$HTTP_CODE" = "000" ] || [ "$HTTP_CODE" = "408" ] || [ "$HTTP_CODE" = "429" ] || [[ "$HTTP_CODE" =~ ^5[0-9]{2}$ ]]; then
    echo "Transient connection or server error (HTTP $HTTP_CODE). Retrying..."
    if [ -n "$CURL_ERR" ]; then
      echo "Curl error: $CURL_ERR"
    fi
  # Fail-fast path: client configuration/authorization errors (401, 403, 404, etc.)
  else
    echo "::error::API request failed with HTTP $HTTP_CODE. Failing fast."
    TRUNCATED_BODY=$(echo -n "$BODY" | head -c 500)
    echo "Response body: $(echo "$TRUNCATED_BODY" | sed -E 's/("token"[[:space:]]*:[[:space:]]*")[^"]+/\1***REDACTED***/g')"
    exit 1
  fi

  if [ "$attempt" -eq "$ATTEMPTS" ]; then
    # The API passed pre-flight but stopped answering (a runner IP can be blocked mid-job):
    # if /version no longer answers either, report blocked or outage instead of a login failure
    if [ "$CURL_RC" -eq 7 ] || [ "$CURL_RC" -eq 28 ]; then
      probe_api
      if [ "${API_RC}" -eq 7 ] || [ "${API_RC}" -eq 28 ]; then
        report_no_api
      fi
    fi
    echo "::error::Failed to log in to OpenShift after $ATTEMPTS attempts. Runner public IP: $(runner_ip)"
    exit 1
  fi

  echo "Login attempt $attempt failed, retrying in $DELAY seconds..."
  sleep "$DELAY"
  DELAY=$((DELAY * 2))
  attempt=$((attempt + 1))
done

# Verify namespace
if [ "$(oc project -q)" != "${NAMESPACE}" ]; then
  echo "Project and token do not match!"
  exit 1
fi

# Version for client, kustomize, server and Kubernetes
echo -e "\nInput Version: ${OC}"
oc version
echo
