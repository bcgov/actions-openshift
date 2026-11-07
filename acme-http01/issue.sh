#!/usr/bin/env bash
# ACME HTTP-01 issuance for one host. GitHub Action wrapper: action.yml.
# Creates a throwaway Pod (lego + idle helper), Service, NetworkPolicy and plain-HTTP
# Route on path /.well-known/acme-challenge for ACME_HOST, waits for lego, copies the
# PEMs out, then deletes everything it created (also on failure).
set -euo pipefail

ACME_HOST="${ACME_HOST:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
ACME_SERVER="${ACME_SERVER:-staging}"
KEY_TYPE="${KEY_TYPE:-rsa2048}"
TIMEOUT="${TIMEOUT:-300}"
OUT_DIR="${OUT_DIR:-${RUNNER_TEMP:-/tmp}/acme-http01}"
# Pinned image; override only for mirrors
LEGO_IMAGE="${LEGO_IMAGE:-docker.io/goacme/lego:v5.6.0@sha256:6f1583fc026a455ea46a7a5858c576105bb69c2e2de69db391cab7f14750350c}"
OC="${OC:-oc}"
# Time for the router to load the Route before ACME validates; a miss counts
# against the 5 failed validations per host per hour limit
CHALLENGE_DELAY=20s

die() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=ACME HTTP-01::$*"; else echo "error: $*" >&2; fi
  exit 1
}

# Escape a value for a double-quoted YAML scalar so it stays one array element
# even if the email local-part contains quotes, commas or backslashes.
yaml_dq() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# Validation (also runs without a cluster)
[[ "$ACME_HOST" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] \
  || die "hostname must be one lowercase FQDN, no scheme, port, path or wildcard."
[[ "$ACME_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "email is not an address."
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] && [ "$TIMEOUT" -ge 30 ] || die "timeout must be an integer >= 30."
case "$ACME_SERVER" in
  staging) server_url="https://acme-staging-v02.api.letsencrypt.org/directory" ;;
  production) server_url="https://acme-v02.api.letsencrypt.org/directory" ;;
  *) die "acme_server must be staging or production." ;;
esac
KEY_TYPE="${KEY_TYPE^^}"
case "$KEY_TYPE" in EC256|EC384|RSA2048|RSA3072|RSA4096) ;; *) die "unsupported key_type." ;; esac

email_yaml="$(yaml_dq "$ACME_EMAIL")"

# Short unique name; label used for cleanup sweeps
suffix="$(printf '%s' "${ACME_HOST}${GITHUB_RUN_ID:-}${RANDOM}" | sha256sum | cut -c1-8)"
NAME="acme-http01-${suffix}"

render() {
  cat <<YAML
apiVersion: v1
kind: List
items:
# Lets the OpenShift router reach the Pod in default-deny namespaces
- apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: ${NAME}
    labels: {app.kubernetes.io/managed-by: acme-http01}
  spec:
    podSelector: {matchLabels: {acme-http01/name: ${NAME}}}
    ingress:
    - from:
      - namespaceSelector: {matchLabels: {network.openshift.io/policy-group: ingress}}
    policyTypes: [Ingress]
- apiVersion: v1
  kind: Pod
  metadata:
    name: ${NAME}
    labels: {app.kubernetes.io/managed-by: acme-http01, acme-http01/name: ${NAME}}
  spec:
    restartPolicy: Never
    activeDeadlineSeconds: $((TIMEOUT + 120))
    volumes: [{name: data, emptyDir: {}}]
    # No runAsNonRoot: the lego image sets no user, so the kubelet refuses to start it
    containers:
    - name: lego
      image: ${LEGO_IMAGE}
      args: [run, --accept-tos, --email, "${email_yaml}", --server, "${server_url}",
             --domains, "${ACME_HOST}", --key-type, "${KEY_TYPE}", --http, --http.address, ":8080",
             --http.delay, "${CHALLENGE_DELAY}", --path, /data/lego]
      ports: [{containerPort: 8080}]
      volumeMounts: [{name: data, mountPath: /data}]
      resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 128Mi}}
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    - name: helper
      image: ${LEGO_IMAGE}
      command: [sleep, "$((TIMEOUT + 60))"]
      volumeMounts: [{name: data, mountPath: /data}]
      resources: {requests: {cpu: 5m, memory: 16Mi}, limits: {memory: 64Mi}}
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
- apiVersion: v1
  kind: Service
  metadata:
    name: ${NAME}
    labels: {app.kubernetes.io/managed-by: acme-http01}
  spec:
    selector: {acme-http01/name: ${NAME}}
    ports: [{name: http, port: 8080, targetPort: 8080}]
- apiVersion: route.openshift.io/v1
  kind: Route
  metadata:
    name: ${NAME}
    labels: {app.kubernetes.io/managed-by: acme-http01}
  spec:
    host: ${ACME_HOST}
    path: /.well-known/acme-challenge
    to: {kind: Service, name: ${NAME}}
    port: {targetPort: http}
YAML
}

if [ "${RENDER_ONLY:-false}" = "true" ]; then render; exit 0; fi

# Why the Pod is stuck; cleanup deletes it, so this is the only record
diagnostics() {
  echo "--- Pod ${NAME} containers"
  "$OC" get "pod/${NAME}" -o jsonpath='{range .status.containerStatuses[*]}{.name}{": "}{.state}{"\n"}{end}' 2>&1 || true
  echo "--- Pod ${NAME} events"
  "$OC" get events --field-selector "involvedObject.name=${NAME}" 2>&1 || true
}

cleanup() {
  "$OC" delete "route/${NAME}" "service/${NAME}" "pod/${NAME}" "networkpolicy/${NAME}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Path-based plain-HTTP Route: the router prefers the longer path, so the
# vanity Route (edge + Redirect) keeps serving everything else.
render | "$OC" apply -f - >/dev/null

echo "Waiting up to ${TIMEOUT}s for lego (${ACME_SERVER}) on ${ACME_HOST}"
deadline=$((SECONDS + TIMEOUT))
state=""
while [ "$SECONDS" -lt "$deadline" ]; do
  state="$("$OC" get "pod/${NAME}" -o jsonpath='{.status.containerStatuses[?(@.name=="lego")].state.terminated.exitCode}' 2>/dev/null || true)"
  [ -n "$state" ] && break
  admitted="$("$OC" get "route/${NAME}" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
  [ "$admitted" != "False" ] || die "challenge Route for ${ACME_HOST} was not admitted (host owned by another namespace?)."
  # A Pod that can't start never logs, so stop rather than wait out the timeout
  waiting="$("$OC" get "pod/${NAME}" -o jsonpath='{.status.containerStatuses[*].state.waiting.reason}' 2>/dev/null || true)"
  case " $waiting " in
    *" ImagePullBackOff "*|*" ErrImagePull "*|*" InvalidImageName "*|*" CreateContainerError "*|*" CreateContainerConfigError "*)
      diagnostics
      die "Pod ${NAME} cannot start: ${waiting}."
      ;;
  esac
  sleep 5
done
"$OC" logs "pod/${NAME}" -c lego --tail=40 2>/dev/null | grep -v -- '-----' || true
[ -n "$state" ] || diagnostics
[ -n "$state" ] || die "lego did not finish within ${TIMEOUT}s (DNS for ${ACME_HOST} must reach this cluster's router)."
[ "$state" = "0" ] || die "lego exited ${state}; see log above."

# Issuance can finish while the helper image is still pulling; wait before oc exec.
helper=""
while [ "$SECONDS" -lt "$deadline" ]; do
  helper="$("$OC" get "pod/${NAME}" -o jsonpath='{.status.containerStatuses[?(@.name=="helper")].state.running.startedAt}' 2>/dev/null || true)"
  [ -n "$helper" ] && break
  sleep 2
done
[ -n "$helper" ] || die "helper container not running within ${TIMEOUT}s; cannot copy issued PEMs."

mkdir -p "$OUT_DIR" && chmod 700 "$OUT_DIR"
fetch() { "$OC" exec "pod/${NAME}" -c helper -- sh -c "cat \$(ls /data/lego/certificates/*$1 | head -1)"; }
fetch "${ACME_HOST}.key" > "${OUT_DIR}/tls.key"
fetch "${ACME_HOST}.crt" > "${OUT_DIR}/fullchain.pem"
fetch "${ACME_HOST}.issuer.crt" > "${OUT_DIR}/ca.pem"
# Leaf = first cert of the bundle
awk '/BEGIN CERTIFICATE/{n++} n==1' "${OUT_DIR}/fullchain.pem" > "${OUT_DIR}/tls.crt"
chmod 600 "${OUT_DIR}"/*
openssl x509 -in "${OUT_DIR}/tls.crt" -noout -checkhost "$ACME_HOST" | grep -q 'does match' || die "issued cert does not match ${ACME_HOST}."
not_after="$(openssl x509 -in "${OUT_DIR}/tls.crt" -noout -enddate | cut -d= -f2)"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  for f in tls.crt ca.pem tls.key; do
    while IFS= read -r line; do [ -n "$line" ] && echo "::add-mask::${line}"; done < "${OUT_DIR}/${f}"
  done
  {
    d="EOF_$(openssl rand -hex 8)"
    echo "tls_certificate<<${d}"; cat "${OUT_DIR}/tls.crt"; echo "${d}"
    echo "tls_ca_certificate<<${d}"; cat "${OUT_DIR}/ca.pem"; echo "${d}"
    echo "tls_private_key<<${d}"; cat "${OUT_DIR}/tls.key"; echo "${d}"
    echo "not_after=${not_after}"
  } >> "$GITHUB_OUTPUT"
fi
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "### ACME HTTP-01" "" "- host=${ACME_HOST} server=${ACME_SERVER} notAfter=${not_after}" >> "$GITHUB_STEP_SUMMARY"
echo "Issued ${ACME_HOST} (${ACME_SERVER}), notAfter ${not_after}; PEMs in ${OUT_DIR}"
