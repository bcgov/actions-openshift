#!/usr/bin/env bash
# Runs after oc-runner has logged in to the namespace. Starts the pg-upgrade Job,
# streams its log and reports the result. Never prints secret values: the Job reads them
# from the namespace Secret itself.
set -euo pipefail

fail() {
  echo "::error::$1"
  if [ -n "${2:-}" ]; then echo "Fix: $2"; fi
  exit 1
}
result() { echo "result=$1" >> "${GITHUB_OUTPUT:-/dev/null}"; }

MODE="${MODE:-upgrade}"
TARGET="${TARGET:-}"
TARGET_SECRET="${TARGET_SECRET:-}"
APP_LABEL="${APP_LABEL:-}"
TIMEOUT="${TIMEOUT:-30m}"
MEMORY_LIMIT="${MEMORY_LIMIT:-1Gi}"
POLL="${POLL:-5}"
ACTION_PATH="${ACTION_PATH:?ACTION_PATH is required}"

NAME_RE='^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$'
SECRET_RE='^[a-z0-9]([-.a-z0-9]{0,251}[a-z0-9])?$'
# Official postgres or postgis/postgis images from Docker Hub, with an explicit tag:
# the Job relies on their entrypoint helpers, and a tag in the workflow is what Renovate updates
IMAGE_RE='^(docker\.io/)?((library/)?postgres|postgis/postgis):[A-Za-z0-9][A-Za-z0-9._-]{0,127}(@sha256:[0-9a-f]{64})?$'

case "$MODE" in
  upgrade | rehearse | rollback) ;;
  *) fail "Invalid mode '${MODE}'." "Use upgrade, rehearse or rollback." ;;
esac
[[ "${SOURCE:-}" =~ $NAME_RE ]] || fail "Invalid source '${SOURCE:-}'." "Set source to the old database's Service name, e.g. myapp-test-database."
[[ "${SECRET:-}" =~ $SECRET_RE ]] || fail "Invalid secret '${SECRET:-}'." "Set secret to the Secret holding database-name, database-user and database-password."
if [ "$MODE" = upgrade ] || [ -n "$TARGET" ]; then
  [[ "$TARGET" =~ $NAME_RE ]] || fail "Invalid target '${TARGET}'." "Set target to the new database's Service name, e.g. myapp-test-database-18."
  [ "$TARGET" != "$SOURCE" ] || fail "source and target are both '${SOURCE}'." "Give the new database its own Service name."
fi
TARGET_SECRET="${TARGET_SECRET:-$SECRET}"
[[ "$TARGET_SECRET" =~ $SECRET_RE ]] || fail "Invalid target_secret '${TARGET_SECRET}'." "Leave it empty to use secret, or name a Secret with the same keys."
if [ "$MODE" != rollback ]; then
  [ -n "${IMAGE:-}" ] || fail "image is required for mode ${MODE}." "Set image to the target database image, e.g. postgres:17.6 or postgis/postgis:17-3.5."
  [[ "$IMAGE" =~ $IMAGE_RE ]] || fail "Unsupported image '${IMAGE}'." "Use an official Docker Hub postgres or postgis/postgis image with a tag, e.g. postgres:17.6. Internal registry images aren't supported."
fi
IMAGE="${IMAGE:-postgres:17}"
[ -z "$APP_LABEL" ] || [[ "$APP_LABEL" =~ $NAME_RE ]] || fail "Invalid app_label '${APP_LABEL}'." "Use the app label of your other objects, e.g. myapp-test, or leave it empty."
[[ "$MEMORY_LIMIT" =~ ^[0-9]+(Mi|Gi)$ ]] || fail "Invalid memory_limit '${MEMORY_LIMIT}'." "Use e.g. 512Mi or 2Gi."
[[ "$TIMEOUT" =~ ^([0-9]+)([smh])$ ]] || fail "Invalid timeout '${TIMEOUT}'." "Use e.g. 30m, 900s or 1h."
case "${BASH_REMATCH[2]}" in s) SECONDS_MAX="${BASH_REMATCH[1]}" ;; m) SECONDS_MAX=$((BASH_REMATCH[1] * 60)) ;; h) SECONDS_MAX=$((BASH_REMATCH[1] * 3600)) ;; esac
[ "$SECONDS_MAX" -ge 120 ] || fail "timeout ${TIMEOUT} is too short." "Use at least 2m."
# Leave the runner a minute after the Job's own deadline to collect logs and clean up
JOB_DEADLINE=$((SECONDS_MAX - 60))

# API errors must fail, never read as "not found": a missing source means "skip"
service_exists() {
  local out
  out="$(oc get service "$1" --ignore-not-found -o name)" \
    || fail "Could not read Service $1 from OpenShift." "Re-run the job; if it repeats, check that the runner can reach the OpenShift API."
  [ -n "$out" ]
}

if ! service_exists "$SOURCE"; then
  if [ "$MODE" = rollback ]; then
    fail "Source Service ${SOURCE} not found, so there is nothing to make writable." "Check source; it must be the old database's Service."
  fi
  echo "::notice::No Service ${SOURCE}: nothing to ${MODE} (new environment, or the old database is already gone)."
  result skipped
  exit 0
fi

MARKER="${TARGET:-$SOURCE}-pg-upgrade"
if [ "$MODE" = upgrade ]; then
  STATUS="$(oc get configmap "$MARKER" --ignore-not-found -o jsonpath='{.data.status}')" \
    || fail "Could not read ConfigMap ${MARKER} from OpenShift." "Re-run the job; if it repeats, check that the runner can reach the OpenShift API."
  case "$STATUS" in
    done)
      echo "${TARGET} was already upgraded from ${SOURCE} (ConfigMap ${MARKER}); nothing to do."
      result already-upgraded
      exit 0
      ;;
    "") ;;
    *)
      fail "ConfigMap ${MARKER} says an upgrade into ${TARGET} is already running or was interrupted." \
        "Wait for the running Job (oc get jobs -l pg-upgrade/target=${TARGET}); if none is running, check its log, then delete ConfigMap ${MARKER} and re-run."
      ;;
  esac
  service_exists "$TARGET" || fail "Target Service ${TARGET} not found." "Deploy the new database (StatefulSet and Service) before this step."
fi

RAND="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
JOB="pgup-${MODE}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${RAND}"
JOB="${JOB:0:63}"
LABEL_KEY="pg-upgrade/target"
LABEL_VAL="${TARGET:-$SOURCE}"

labels_json() { # extra key=value pairs
  jq -n --arg app "$APP_LABEL" --arg k "$LABEL_KEY" --arg v "$LABEL_VAL" \
    '{($k): $v} + (if $app == "" then {} else {app: $app} end)'
}

CREATED_MARKER=0
NETPOLS=()
# none: no Job yet; running: outcome unknown; failed or ok: the Job has finished
JOB_STATE=none
cleanup() {
  rc=$?
  if [ "$JOB_STATE" = running ]; then
    # The Job may still be copying: keep its network access and the lock, so no second run starts
    echo "::error::Lost track of Job ${JOB}; it may still be running. ConfigMap ${MARKER} keeps other runs out."
    echo "Fix: check oc logs job/${JOB}. If it succeeded, mark it done: oc patch configmap ${MARKER} --type merge -p '{\"data\":{\"status\":\"done\"}}'; if it failed, delete ConfigMap ${MARKER} and NetworkPolicies ${JOB}-*, then re-run."
    exit "$rc"
  fi
  for np in "${NETPOLS[@]}"; do oc delete networkpolicy "$np" --ignore-not-found > /dev/null 2>&1 || true; done
  if [ "$CREATED_MARKER" = 1 ] && [ "$JOB_STATE" != ok ]; then
    oc delete configmap "$MARKER" --ignore-not-found > /dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM INT

if [ "$MODE" = upgrade ]; then
  # Lock and record: oc create fails if another run already holds it
  jq -n --arg n "$MARKER" --argjson l "$(labels_json)" --arg s "$SOURCE" --arg t "$TARGET" --arg j "$JOB" \
    --arg run "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
    '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: $n, labels: $l},
      data: {status: "running", source: $s, target: $t, job: $j, run: $run}}' \
    | oc create -f - > /dev/null || fail "Could not create ConfigMap ${MARKER} to lock the upgrade." "Another run may have started; re-run when it finishes."
  CREATED_MARKER=1
fi

# Temporary NetworkPolicies so the Job pod (and only it) can reach each database pod
allow_job_to() { # service suffix
  local selector np
  selector="$(oc get service "$1" -o json | jq -c '.spec.selector // {}')"
  [ "$selector" != "{}" ] || fail "Service $1 has no selector, so its database pods can't be found." "Point source/target at the Service in front of the database pod."
  np="${JOB}-${2}"
  jq -n --arg n "${np:0:63}" --argjson l "$(labels_json)" --argjson sel "$selector" --arg job "$JOB" \
    '{apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: {name: $n, labels: $l},
      spec: {podSelector: {matchLabels: $sel}, policyTypes: ["Ingress"],
        ingress: [{from: [{podSelector: {matchLabels: {"pg-upgrade/job": $job}}}], ports: [{protocol: "TCP", port: 5432}]}]}}' \
    | oc create -f - > /dev/null || fail "Could not create NetworkPolicy ${np:0:63}." "The deploy token needs permission to create NetworkPolicies in the namespace."
  NETPOLS+=("${np:0:63}")
}
allow_job_to "$SOURCE" src
if [ "$MODE" = upgrade ]; then allow_job_to "$TARGET" tgt; fi

secret_env() { # prefix secret
  jq -n --arg p "$1" --arg s "$2" '[
    {name: ($p + "_DB"), valueFrom: {secretKeyRef: {name: $s, key: "database-name"}}},
    {name: ($p + "_USER"), valueFrom: {secretKeyRef: {name: $s, key: "database-user"}}},
    {name: ($p + "_PASSWORD"), valueFrom: {secretKeyRef: {name: $s, key: "database-password"}}}]'
}
ENV_JSON="$(jq -n --arg m "$MODE" --arg s "$SOURCE" --arg t "$TARGET" \
  '[{name: "MODE", value: $m}, {name: "SOURCE_HOST", value: $s}, {name: "TARGET_HOST", value: $t}, {name: "HOME", value: "/work"}]')"
ENV_JSON="$(jq -s 'add' <(echo "$ENV_JSON") <(secret_env SRC "$SECRET"))"
if [ "$MODE" = upgrade ]; then ENV_JSON="$(jq -s 'add' <(echo "$ENV_JSON") <(secret_env TGT "$TARGET_SECRET"))"; fi

POD_LABELS="$(labels_json | jq -c --arg job "$JOB" '. + {"pg-upgrade/job": $job}')"
jq -n --arg n "$JOB" --argjson l "$(labels_json)" --argjson pl "$POD_LABELS" --arg image "$IMAGE" \
  --rawfile script "${ACTION_PATH}/scripts/job.sh" --argjson env "$ENV_JSON" \
  --arg mem "$MEMORY_LIMIT" --argjson deadline "$JOB_DEADLINE" '{
  apiVersion: "batch/v1", kind: "Job", metadata: {name: $n, labels: $l},
  spec: {backoffLimit: 0, activeDeadlineSeconds: $deadline, ttlSecondsAfterFinished: 86400,
    template: {metadata: {labels: $pl}, spec: {restartPolicy: "Never",
      containers: [{name: "pg-upgrade", image: $image, imagePullPolicy: "IfNotPresent",
        command: ["bash", "-c", $script], env: $env,
        resources: {requests: {cpu: "100m", memory: "256Mi"}, limits: {memory: $mem}},
        securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true,
          capabilities: {drop: ["ALL"]}, seccompProfile: {type: "RuntimeDefault"}},
        volumeMounts: [{name: "work", mountPath: "/work"}, {name: "socket", mountPath: "/var/run/postgresql"},
          {name: "data", mountPath: "/var/lib/postgresql/data"}]}],
      volumes: [{name: "work", emptyDir: {}}, {name: "socket", emptyDir: {}}, {name: "data", emptyDir: {}}]}}}}' \
  | oc create -f - > /dev/null || fail "Could not create Job ${JOB}." "The deploy token needs permission to create Jobs in the namespace."
JOB_STATE=running
echo "Started Job ${JOB} (${MODE}: ${SOURCE}${TARGET:+ -> ${TARGET}}, image ${IMAGE})"

# Wait for the pod to start, failing fast on image or secret problems
START=$(date +%s)
POD=""
while :; do
  # Polls tolerate a failed API call and try again
  POD="$(oc get pods -l "job-name=${JOB}" -o name 2> /dev/null | head -n 1)" || POD=""
  if [ -n "$POD" ]; then
    PHASE="$(oc get "$POD" -o jsonpath='{.status.phase}' 2> /dev/null)" || PHASE=""
    WAITING="$(oc get "$POD" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2> /dev/null)" || WAITING=""
    case "$WAITING" in
      ErrImagePull | ImagePullBackOff | InvalidImageName)
        oc delete job "$JOB" --wait=true > /dev/null 2>&1 && JOB_STATE=failed
        fail "The Job can't pull image ${IMAGE} (${WAITING})." "Check the image name and tag on Docker Hub." ;;
      CreateContainerConfigError)
        oc delete job "$JOB" --wait=true > /dev/null 2>&1 && JOB_STATE=failed
        fail "The Job can't start: a Secret or key is missing." "Check that ${SECRET}${TARGET:+ and ${TARGET_SECRET}} hold database-name, database-user and database-password." ;;
    esac
    case "$PHASE" in Running | Succeeded | Failed) break ;; esac
  fi
  if [ $(($(date +%s) - START)) -ge 300 ]; then
    oc delete job "$JOB" --wait=true > /dev/null 2>&1 && JOB_STATE=failed
    fail "Job ${JOB} did not start within 5 minutes." "Check quota and events in the namespace."
  fi
  sleep "$POLL"
done

oc logs -f "$POD" || true

while :; do
  SUCCEEDED="$(oc get job "$JOB" -o jsonpath='{.status.succeeded}' 2> /dev/null)" || SUCCEEDED=""
  FAILED="$(oc get job "$JOB" -o jsonpath='{.status.failed}' 2> /dev/null)" || FAILED=""
  [ "${SUCCEEDED:-0}" -ge 1 ] && break
  if [ "${FAILED:-0}" -ge 1 ]; then
    JOB_STATE=failed
    REASON="$(oc get job "$JOB" -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}' 2> /dev/null)" || REASON=""
    if [ "$REASON" = DeadlineExceeded ]; then
      fail "Job ${JOB} hit its ${JOB_DEADLINE}s deadline." "Raise timeout. If it was an upgrade and the source stays read-only, run mode: rollback."
    fi
    fail "Job ${JOB} failed (${MODE}); see its log above." "Fix the cause in the log and re-run. The log stays available for a day: oc logs job/${JOB}"
  fi
  [ $(($(date +%s) - START)) -lt "$SECONDS_MAX" ] || fail "Job ${JOB} did not finish in time." "Check it with oc logs job/${JOB}."
  sleep "$POLL"
done

JOB_STATE=ok
case "$MODE" in
  upgrade)
    oc patch configmap "$MARKER" --type merge -p '{"data":{"status":"done"}}' > /dev/null \
      || fail "Upgrade succeeded but ConfigMap ${MARKER} could not be marked done." "Run: oc patch configmap ${MARKER} --type merge -p '{\"data\":{\"status\":\"done\"}}'"
    result upgraded
    ;;
  rehearse) result rehearsed ;;
  rollback)
    oc delete configmap "${SOURCE}-pg-upgrade" "${TARGET:-${SOURCE}}-pg-upgrade" --ignore-not-found > /dev/null || true
    result rolled-back
    ;;
esac
