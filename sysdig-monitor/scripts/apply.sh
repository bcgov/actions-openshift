#!/usr/bin/env bash
#
# Apply Sysdig monitoring for one app:
#   1. Discover alert template files in the consuming repo's alerts dir.
#   2. Resolve team-member emails via the Sysdig API (the token is team-scoped).
#   3. Upsert one EMAIL notification channel for the team.
#   4. Upsert one alert per (component × alert template) pairing.
#
# Idempotent: safe to re-run on every PROD deploy.
# Additive: never deletes Sysdig alerts when template files are removed —
# clean those up in the Sysdig UI.
# No-op (exit 0) if SYSDIG_API_TOKEN is empty or the alerts dir is missing/empty
# — monitoring is observability, not a release gate.

set -euo pipefail

if [[ -z "${SYSDIG_API_TOKEN:-}" ]]; then
  echo "::warning::SYSDIG_API_TOKEN is empty; skipping Sysdig monitoring setup."
  exit 0
fi

: "${SYSDIG_API_URL:?required}"
: "${OC_NAMESPACE:?required}"
: "${APP:?required}"
: "${COMPONENTS:?required}"
: "${ALERT_DURATION_MINUTES:?required}"
: "${CHANNEL_TEMPLATE:?required}"
: "${ALERTS_DIR:?required}"

DEBUG="${DEBUG:-false}"
DURATION_SECONDS=$(( ALERT_DURATION_MINUTES * 60 ))
CHANNEL_NAME="${APP}-team-email"

log() { echo "[sysdig-monitor] $*"; }
# debug() writes to stderr so it never pollutes the stdout JSON captured
# by callers like `$(api GET ...)`.
# The `if` form (rather than `A && B || true`) keeps the exit status 0 under
# `set -e` when DEBUG is off, without tripping SC2015.
debug() { if [[ "${DEBUG}" == "true" ]]; then echo "[sysdig-monitor:debug] $*" >&2; fi; }

# ---------------------------------------------------------------------------
# 1. Discover alert template files in the consuming repo
# ---------------------------------------------------------------------------

if [[ ! -d "${ALERTS_DIR}" ]]; then
  echo "::warning::Alerts directory not found at ${ALERTS_DIR}; nothing to apply."
  exit 0
fi

shopt -s nullglob
ALERT_FILES=( "${ALERTS_DIR}"/*.json )
shopt -u nullglob

if [[ ${#ALERT_FILES[@]} -eq 0 ]]; then
  echo "::warning::No *.json alert templates in ${ALERTS_DIR}; nothing to apply."
  exit 0
fi

# Pre-flight: validate each file is parseable JSON and the filename is a safe
# identifier (it becomes part of the alert name sent to Sysdig).
for alert_file in "${ALERT_FILES[@]}"; do
  filename="$(basename "${alert_file}" .json)"
  if ! [[ "${filename}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    echo "::error::Alert filename '${filename}.json' must match ^[a-z0-9][a-z0-9_-]*$"
    exit 1
  fi
  if ! jq empty "${alert_file}" >/dev/null 2>&1; then
    echo "::error::${alert_file} is not valid JSON."
    exit 1
  fi
done
log "Found ${#ALERT_FILES[@]} alert template(s) in ${ALERTS_DIR}."

api() {
  # api METHOD PATH [JSON_BODY]
  # Note: request bodies are intentionally never logged. They contain
  # recipient emails and would land in GitHub Action logs.
  local method="$1" path="$2" body="${3:-}"
  local url="${SYSDIG_API_URL}${path}"
  local args=(
    -sS
    -X "${method}"
    -H "Authorization: Bearer ${SYSDIG_API_TOKEN}"
    -H "Content-Type: application/json"
    -H "Accept: application/json"
  )
  if [[ -n "${body}" ]]; then
    args+=(-d "${body}")
  fi
  debug "${method} ${url}"
  curl "${args[@]}" "${url}"
}

# ---------------------------------------------------------------------------
# 2. Resolve team-member emails (excluding auto-injected platform admins)
# ---------------------------------------------------------------------------
#
# BC Gov's Sysdig install auto-adds platform-services + DXC support staff to
# every team with admin=true. They need view access for support but should
# NOT be on the alert distribution. CR-managed users have admin=false.
#
# The token can list /api/teams (which carries .userRoles[] per team with the
# admin flag) but not GET its own team directly. So we fetch /api/teams, find
# our team by currentTeam id from /api/user/me, and filter userRoles where
# admin == false. Each entry's .userName is the email.

log "Resolving current team via ${SYSDIG_API_URL}/api/user/me"
ME_JSON="$(api GET /api/user/me)"
CURRENT_TEAM_ID="$(echo "${ME_JSON}" | jq -r '.user.currentTeam // empty')"

if [[ -z "${CURRENT_TEAM_ID}" ]]; then
  echo "::error::Could not resolve currentTeam from /api/user/me."
  # Print only the errors field, not the full response — the user object
  # contains the token owner's email.
  echo "${ME_JSON}" | jq -c '.errors // {hint: "unexpected response shape — re-run with DEBUG=true to investigate locally"}'
  exit 1
fi
log "Current team id=${CURRENT_TEAM_ID}"

log "Resolving non-admin team members via /api/teams"
TEAMS_JSON="$(api GET /api/teams)"

EMAIL_RECIPIENTS="$(echo "${TEAMS_JSON}" | jq -c --argjson teamId "${CURRENT_TEAM_ID}" '
  [ .teams[]
    | select(.id == $teamId)
    | .userRoles[]?
    | select(.admin == false)
    | .userName
    | select(. != null and . != "" and test("@"))
  ] | unique
')"

EMAIL_COUNT="$(echo "${EMAIL_RECIPIENTS}" | jq 'length')"
if [[ "${EMAIL_COUNT}" == "0" ]]; then
  echo "::warning::No team members resolved — channel will be created with an empty recipient list."
fi
log "Resolved ${EMAIL_COUNT} recipient(s)."
# Email addresses are intentionally not logged — they're PII and would land
# in GitHub Action logs. To inspect the recipient list, look at the channel
# directly in the Sysdig UI.

# ---------------------------------------------------------------------------
# 3. Upsert EMAIL notification channel
# ---------------------------------------------------------------------------

log "Upserting notification channel: ${CHANNEL_NAME}"

CHANNEL_PAYLOAD="$(
  jq -c \
    --arg name "${CHANNEL_NAME}" \
    --argjson recipients "${EMAIL_RECIPIENTS}" \
    --argjson teamId "${CURRENT_TEAM_ID}" \
    '
      .name = $name
      | .teamId = $teamId
      | .options.emailRecipients = $recipients
    ' "${CHANNEL_TEMPLATE}"
)"

CHANNELS_JSON="$(api GET /api/notificationChannels)"
EXISTING_CHANNEL_ID="$(
  echo "${CHANNELS_JSON}" \
    | jq -r --arg name "${CHANNEL_NAME}" \
        '[.notificationChannels[]? | select(.name == $name) | .id][0] // empty'
)"

if [[ -n "${EXISTING_CHANNEL_ID}" ]]; then
  log "Updating existing channel id=${EXISTING_CHANNEL_ID}"
  CURRENT="$(api GET "/api/notificationChannels/${EXISTING_CHANNEL_ID}")"
  VERSION="$(echo "${CURRENT}" | jq '.notificationChannel.version // 0')"
  UPDATE_PAYLOAD="$(
    echo "${CHANNEL_PAYLOAD}" \
      | jq --argjson id "${EXISTING_CHANNEL_ID}" --argjson v "${VERSION}" '
          { notificationChannel: (. + { id: $id, version: $v }) }
        '
  )"
  RESP="$(api PUT "/api/notificationChannels/${EXISTING_CHANNEL_ID}" "${UPDATE_PAYLOAD}")"
  CHANNEL_ID="${EXISTING_CHANNEL_ID}"
else
  log "Creating new channel"
  CREATE_PAYLOAD="$(echo "${CHANNEL_PAYLOAD}" | jq '{ notificationChannel: . }')"
  RESP="$(api POST /api/notificationChannels "${CREATE_PAYLOAD}")"
  CHANNEL_ID="$(echo "${RESP}" | jq -r '.notificationChannel.id // empty')"
fi

if [[ -z "${CHANNEL_ID}" ]]; then
  echo "::error::Failed to resolve notification channel id."
  # Print only the errors field, not the full response — channel responses
  # include the email recipient list.
  echo "${RESP}" | jq -c '.errors // {hint: "unexpected response shape — re-run with DEBUG=true to investigate locally"}'
  exit 1
fi
log "Channel id=${CHANNEL_ID}"

# ---------------------------------------------------------------------------
# 4. Upsert alerts per component × per template file
# ---------------------------------------------------------------------------

ALERTS_JSON="$(api GET /api/v2/alerts)"

upsert_alert() {
  local component="$1" template_path="$2" rule_key="$3"
  local alert_name="${APP}-${component}-${rule_key}"
  log "Upserting alert: ${alert_name}"

  local body
  body="$(
    jq -c \
      --arg name "${alert_name}" \
      --arg app "${APP}" \
      --arg namespace "${OC_NAMESPACE}" \
      --arg component "${component}" \
      --arg duration_min "${ALERT_DURATION_MINUTES}" \
      --argjson duration_sec "${DURATION_SECONDS}" \
      --argjson channel_id "${CHANNEL_ID}" \
      '
        .name = $name
        | .description = (
            (.description // "")
            | gsub("__APP__"; $app)
            | gsub("__NAMESPACE__"; $namespace)
            | gsub("__COMPONENT__"; $component)
            | gsub("__DURATION_MINUTES__"; $duration_min)
          )
        | .config.query = (
            .config.query
            | gsub("__APP__"; $app)
            | gsub("__NAMESPACE__"; $namespace)
            | gsub("__COMPONENT__"; $component)
          )
        | .config.duration = $duration_sec
        | .notificationChannelConfigList = [ { type: "EMAIL", channelId: $channel_id } ]
      ' "${template_path}"
  )"

  local existing_id
  existing_id="$(
    echo "${ALERTS_JSON}" \
      | jq -r --arg name "${alert_name}" \
          '[.alerts[]? | select(.name == $name) | .id][0] // empty'
  )"

  local resp
  if [[ -n "${existing_id}" ]]; then
    local current version payload
    current="$(api GET "/api/v2/alerts/${existing_id}")"
    version="$(echo "${current}" | jq '.alert.version // 0')"
    payload="$(echo "${body}" | jq --argjson id "${existing_id}" --argjson v "${version}" '
      { alert: (. + { id: $id, version: $v }) }
    ')"
    resp="$(api PUT "/api/v2/alerts/${existing_id}" "${payload}")"
  else
    local payload
    payload="$(echo "${body}" | jq '{ alert: . }')"
    resp="$(api POST /api/v2/alerts "${payload}")"
  fi

  if echo "${resp}" | jq -e '.errors' > /dev/null 2>&1; then
    echo "::error::Alert ${alert_name} upsert failed:"
    echo "${resp}" | jq '.errors'
    exit 1
  fi
}

IFS=',' read -r -a COMPONENT_LIST <<< "${COMPONENTS}"
for raw in "${COMPONENT_LIST[@]}"; do
  component="$(echo "${raw}" | xargs)"  # trim whitespace
  [[ -z "${component}" ]] && continue

  for alert_file in "${ALERT_FILES[@]}"; do
    rule_key="$(basename "${alert_file}" .json)"
    upsert_alert "${component}" "${alert_file}" "${rule_key}"
  done
done

log "Done."
