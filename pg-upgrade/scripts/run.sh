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
# Every mode runs the image with the database credentials, so every mode checks it
[ -n "${IMAGE:-}" ] || fail "image is required." "Set image to the target database image, e.g. postgres:17.6 or postgis/postgis:17-3.5."
[[ "$IMAGE" =~ $IMAGE_RE ]] || fail "Unsupported image '${IMAGE}'." "Use an official Docker Hub postgres or postgis/postgis image with a tag, e.g. postgres:17.6. Internal registry images aren't supported."
[ -z "$APP_LABEL" ] || [[ "$APP_LABEL" =~ $NAME_RE ]] || fail "Invalid app_label '${APP_LABEL}'." "Use the app label of your other objects, e.g. myapp-test, or leave it empty."
[[ "$MEMORY_LIMIT" =~ ^([0-9]+)(Mi|Gi)$ ]] || fail "Invalid memory_limit '${MEMORY_LIMIT}'." "Use e.g. 512Mi or 2Gi."
MEM_MI="${BASH_REMATCH[1]}"
[ "${BASH_REMATCH[2]}" = Mi ] || MEM_MI=$((MEM_MI * 1024))
[ "$MEM_MI" -ge 256 ] || fail "memory_limit ${MEMORY_LIMIT} is below the Job's 256Mi request." "Use 256Mi or more."
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
if [ "$MODE" = upgrade ] || [ "$MODE" = rollback ]; then
  STATUS="$(oc get configmap "$MARKER" --ignore-not-found -o jsonpath='{.data.status}')" \
    || fail "Could not read ConfigMap ${MARKER} from OpenShift." "Re-run the job; if it repeats, check that the runner can reach the OpenShift API."
  if [ "$MODE" = rollback ] && [ "$STATUS" != running ]; then STATUS=rollback-ok; fi
  case "$STATUS" in
    rollback-ok) ;;
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
  [ "$MODE" = rollback ] || service_exists "$TARGET" || fail "Target Service ${TARGET} not found." "Deploy the new database (StatefulSet and Service) before this step."
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
TMPFILES=()
# none: no Job yet; running: outcome unknown; failed or ok: the Job has finished
JOB_STATE=none
cleanup() {
  rc=$?
  rm -f "${TMPFILES[@]}"
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
  lock_err="$(mktemp)"
  jq -n --arg n "$MARKER" --argjson l "$(labels_json)" --arg s "$SOURCE" --arg t "$TARGET" --arg j "$JOB" \
    --arg run "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
    '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: $n, labels: $l},
      data: {status: "running", source: $s, target: $t, job: $j, run: $run}}' \
    | oc create -f - > /dev/null 2> "$lock_err" || {
    if grep -q AlreadyExists "$lock_err"; then
      fail "ConfigMap ${MARKER} already exists, so another run holds the upgrade lock." "Re-run when that run finishes."
    fi
    fail "Could not create ConfigMap ${MARKER} to lock the upgrade: $(head -c 300 "$lock_err")" "Check the OpenShift API is reachable from this runner, then re-run."
  }
  CREATED_MARKER=1
  rm -f "$lock_err"
fi

RUN_KEY="$JOB"

# NetworkPolicies add up once a policy selects a pod, but the first one to select a pod blocks
# every client it doesn't allow. So the Job only gets its own path to a database pod that is
# already isolated; a pod no policy selects is reachable as it is.
allow_job_to() { # service suffix
  local selector labelsel pods nps isolated np
  selector="$(oc get service "$1" -o json | jq -c '.spec.selector // {}')" \
    || fail "Could not read Service $1 from OpenShift." "Re-run the job; if it repeats, check that the runner can reach the OpenShift API."
  [ "$selector" != "{}" ] || fail "Service $1 has no selector, so its database pods can't be found." "Point source/target at the Service in front of the database pod."
  labelsel="$(jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")' <<< "$selector")"
  # Namespace-wide lists can exceed the argument limit, so jq reads them from files
  pods="$(mktemp)"
  nps="$(mktemp)"
  TMPFILES+=("$pods" "$nps")
  oc get pods -l "$labelsel" -o json > "$pods" || fail "Could not list the pods behind Service $1." "Re-run the job."
  oc get networkpolicy -o json > "$nps" || fail "Could not list NetworkPolicies." "The deploy token needs to read NetworkPolicies in the namespace."
  isolated="$(jq -rn --slurpfile pods "$pods" --slurpfile nps "$nps" '
    ($pods[0].items[0].metadata.labels // null) as $l
    | if $l == null then "unknown" else
        [$nps[0].items[] | select((.spec.policyTypes // ["Ingress"]) | index("Ingress")) | .spec.podSelector
          | select((.matchExpressions // []) == [])
          | select((.matchLabels // {}) | to_entries | all(.value == $l[.key]))] | if length > 0 then "yes" else "no" end
      end')"
  if [ "$isolated" != yes ]; then
    echo "Service $1: no NetworkPolicy found that isolates its pods (${isolated}); adding none"
    return 0
  fi
  np="${JOB}-${2}"
  np="${np:0:63}"
  jq -n --arg n "$np" --argjson l "$(labels_json)" --argjson sel "$selector" --arg run "$RUN_KEY" \
    '{apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: {name: $n, labels: $l},
      spec: {podSelector: {matchLabels: $sel}, policyTypes: ["Ingress"],
        ingress: [{from: [{podSelector: {matchLabels: {"pg-upgrade/run": $run}}}], ports: [{protocol: "TCP", port: 5432}]}]}}' \
    | oc create -f - > /dev/null || fail "Could not create NetworkPolicy ${np}." "The deploy token needs permission to create NetworkPolicies in the namespace."
  NETPOLS+=("$np")
  echo "Service $1: NetworkPolicy ${np} lets this run's Job pods connect"
}
allow_job_to "$SOURCE" src
if [ "$MODE" = upgrade ]; then allow_job_to "$TARGET" tgt; fi

secret_env() { # prefix secret
  jq -n --arg p "$1" --arg s "$2" '[
    {name: ($p + "_DB"), valueFrom: {secretKeyRef: {name: $s, key: "database-name"}}},
    {name: ($p + "_USER"), valueFrom: {secretKeyRef: {name: $s, key: "database-user"}}},
    {name: ($p + "_PASSWORD"), valueFrom: {secretKeyRef: {name: $s, key: "database-password"}}}]'
}

# Runs one Job to completion, streaming its log. Returns 1 if it failed; fails the step for
# problems that mean it never ran (image, secret, quota).
run_job() { # mode name deadline-seconds
  local mode="$1" name="$2" deadline="$3" env pod_labels start pod phase waiting succeeded failed reason
  env="$(jq -n --arg m "$mode" --arg s "$SOURCE" --arg t "$TARGET" \
    '[{name: "MODE", value: $m}, {name: "SOURCE_HOST", value: $s}, {name: "TARGET_HOST", value: $t}, {name: "HOME", value: "/work"}]')"
  env="$(jq -s 'add' <(echo "$env") <(secret_env SRC "$SECRET"))"
  if [ "$mode" = upgrade ]; then env="$(jq -s 'add' <(echo "$env") <(secret_env TGT "$TARGET_SECRET"))"; fi
  pod_labels="$(labels_json | jq -c --arg job "$name" --arg run "$RUN_KEY" '. + {"pg-upgrade/job": $job, "pg-upgrade/run": $run}')"
  jq -n --arg n "$name" --argjson l "$(labels_json)" --argjson pl "$pod_labels" --arg image "$IMAGE" \
    --rawfile script "${ACTION_PATH}/scripts/job.sh" --argjson env "$env" \
    --arg mem "$MEMORY_LIMIT" --argjson deadline "$deadline" '{
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
    | oc create -f - > /dev/null || fail "Could not create Job ${name}." "The deploy token needs permission to create Jobs in the namespace."
  JOB_STATE=running
  echo "Started Job ${name} (${mode}: ${SOURCE}${TARGET:+ -> ${TARGET}}, image ${IMAGE})"

  # Wait for the pod to start, failing fast on image or secret problems. Polls retry failed API calls.
  start=$(date +%s)
  while :; do
    pod="$(oc get pods -l "job-name=${name}" -o name 2> /dev/null | head -n 1)" || pod=""
    if [ -n "$pod" ]; then
      phase="$(oc get "$pod" -o jsonpath='{.status.phase}' 2> /dev/null)" || phase=""
      waiting="$(oc get "$pod" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2> /dev/null)" || waiting=""
      case "$waiting" in
        ErrImagePull | ImagePullBackOff | InvalidImageName)
          oc delete job "$name" --wait=true > /dev/null 2>&1 && JOB_STATE=failed
          fail "The Job can't pull image ${IMAGE} (${waiting})." "Check the image name and tag on Docker Hub." ;;
        CreateContainerConfigError)
          oc delete job "$name" --wait=true > /dev/null 2>&1 && JOB_STATE=failed
          fail "The Job can't start: a Secret or key is missing." "Check that ${SECRET}${TARGET:+ and ${TARGET_SECRET}} hold database-name, database-user and database-password." ;;
      esac
      case "$phase" in Running | Succeeded | Failed) break ;; esac
    fi
    if [ $(($(date +%s) - start)) -ge 300 ]; then
      oc delete job "$name" --wait=true > /dev/null 2>&1 && JOB_STATE=failed
      fail "Job ${name} did not start within 5 minutes." "Check quota and events in the namespace."
    fi
    sleep "$POLL"
  done

  oc logs -f "$pod" || true

  while :; do
    succeeded="$(oc get job "$name" -o jsonpath='{.status.succeeded}' 2> /dev/null)" || succeeded=""
    failed="$(oc get job "$name" -o jsonpath='{.status.failed}' 2> /dev/null)" || failed=""
    if [ "${succeeded:-0}" -ge 1 ]; then
      JOB_STATE=ok
      return 0
    fi
    if [ "${failed:-0}" -ge 1 ]; then
      JOB_STATE=failed
      reason="$(oc get job "$name" -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}' 2> /dev/null)" || reason=""
      if [ "$reason" = DeadlineExceeded ]; then
        echo "::error::Job ${name} hit its ${deadline}s deadline."
      else
        echo "::error::Job ${name} failed (${mode}); see its log above."
      fi
      return 1
    fi
    [ $(($(date +%s) - start)) -lt $((deadline + 60)) ] || fail "Job ${name} did not finish in time." "Check it with oc logs job/${name}."
    sleep "$POLL"
  done
}

if ! run_job "$MODE" "$JOB" "$JOB_DEADLINE"; then
  if [ "$MODE" = upgrade ]; then
    # The Job lifts the write pause itself, unless it was killed (OOM, node loss); make sure
    echo "Making sure ${SOURCE} accepts writes again"
    if ( run_job rollback "${JOB:0:59}-rb" 240 ); then
      fail "Upgrade failed; nothing is in use from ${TARGET} and ${SOURCE} accepts writes." "Fix the cause in the log above and re-run. The log stays available for a day: oc logs job/${JOB}"
    fi
    fail "Upgrade failed and ${SOURCE} may still be read-only." "Run this action with mode: rollback, then fix the cause in the log above and re-run."
  fi
  fail "${MODE^} failed." "Fix the cause in the log above and re-run. The log stays available for a day: oc logs job/${JOB}"
fi

case "$MODE" in
  upgrade)
    oc patch configmap "$MARKER" --type merge -p '{"data":{"status":"done"}}' > /dev/null \
      || fail "Upgrade succeeded but ConfigMap ${MARKER} could not be marked done." "Run: oc patch configmap ${MARKER} --type merge -p '{\"data\":{\"status\":\"done\"}}'"
    result upgraded
    ;;
  rehearse) result rehearsed ;;
  rollback)
    oc delete configmap "$MARKER" --ignore-not-found > /dev/null || true
    result rolled-back
    ;;
esac
