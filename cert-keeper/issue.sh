#!/usr/bin/env bash
# ACME HTTP-01 issuance for one host. GitHub Action wrapper: action.yml.
# Creates a throwaway Pod (lego + idle helper), Service, NetworkPolicy and plain-HTTP
# Route on path /.well-known/acme-challenge for ACME_HOST, waits for lego, copies the
# PEMs out, then deletes everything it created (also on failure).
set -euo pipefail

ACME_HOST="${ACME_HOST:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
CA="${CA:-letsencrypt}"
KEY_TYPE="${KEY_TYPE:-rsa2048}"
TIMEOUT="${TIMEOUT:-300}"
OUT_DIR="${OUT_DIR:-${RUNNER_TEMP:-/tmp}/cert-keeper}"
# Pinned image; override only for mirrors
LEGO_IMAGE="${LEGO_IMAGE:-docker.io/goacme/lego:v5.6.0@sha256:6f1583fc026a455ea46a7a5858c576105bb69c2e2de69db391cab7f14750350c}"
OC="${OC:-oc}"
RETRY_DELAY="${RETRY_DELAY:-10}"
# How long to keep retrying the PEM copy, and the Pod outlives it: the API can
# refuse connections for minutes after issuance, and a finished Pod cannot be
# exec'd into, which loses the certificate
COPY_WINDOW="${COPY_WINDOW:-900}"
CLEANUP_WINDOW="${CLEANUP_WINDOW:-300}"
# Time for the router to load the Route before ACME validates; a miss counts
# against the 5 failed validations per host per hour limit
CHALLENGE_DELAY=20s

die() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=cert-keeper::$*"; else echo "error: $*" >&2; fi
  exit 1
}

# The API can drop for a minute or two; an issued certificate must survive that
retry() {
  local until=$((SECONDS + $1))
  shift
  while true; do
    "$@" && return 0
    [ "$SECONDS" -lt "$until" ] || return 1
    sleep "$RETRY_DELAY"
  done
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
# The contact email is optional; when given it must look like an address
[[ -z "$ACME_EMAIL" || "$ACME_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "email is not an address."
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] && [ "$TIMEOUT" -ge 30 ] || die "timeout must be an integer >= 30."
case "$CA" in
  letsencrypt-staging) server_url="https://acme-staging-v02.api.letsencrypt.org/directory" ;;
  letsencrypt) server_url="https://acme-v02.api.letsencrypt.org/directory" ;;
  *) die "ca must be letsencrypt or letsencrypt-staging." ;;
esac
KEY_TYPE="${KEY_TYPE^^}"
case "$KEY_TYPE" in EC256|EC384|RSA2048|RSA3072|RSA4096) ;; *) die "unsupported key_type." ;; esac

# Passed to lego only when set; lego registers an account without one
email_args=""
if [ -n "$ACME_EMAIL" ]; then
  email_args=", --email, \"$(yaml_dq "$ACME_EMAIL")\""
fi

# Short unique name; label used for cleanup sweeps
suffix="$(printf '%s' "${ACME_HOST}${GITHUB_RUN_ID:-}${RANDOM}" | sha256sum | cut -c1-8)"
NAME="cert-keeper-${suffix}"

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
    labels: {app.kubernetes.io/managed-by: cert-keeper}
  spec:
    podSelector: {matchLabels: {cert-keeper/name: ${NAME}}}
    ingress:
    - from:
      - namespaceSelector: {matchLabels: {network.openshift.io/policy-group: ingress}}
    policyTypes: [Ingress]
- apiVersion: v1
  kind: Pod
  metadata:
    name: ${NAME}
    labels: {app.kubernetes.io/managed-by: cert-keeper, cert-keeper/name: ${NAME}}
  spec:
    restartPolicy: Never
    activeDeadlineSeconds: $((TIMEOUT + COPY_WINDOW + 120))
    volumes: [{name: data, emptyDir: {}}]
    # No runAsNonRoot: the lego image sets no user, so the kubelet refuses to start it
    containers:
    - name: lego
      image: ${LEGO_IMAGE}
      args: [run, --accept-tos${email_args}, --server, "${server_url}",
             --domains, "${ACME_HOST}", --key-type, "${KEY_TYPE}", --http, --http.address, ":8080",
             --http.delay, "${CHALLENGE_DELAY}", --path, /data/lego]
      ports: [{containerPort: 8080}]
      volumeMounts: [{name: data, mountPath: /data}]
      resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 128Mi}}
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    - name: helper
      image: ${LEGO_IMAGE}
      command: [sleep, "$((TIMEOUT + COPY_WINDOW + 60))"]
      volumeMounts: [{name: data, mountPath: /data}]
      resources: {requests: {cpu: 5m, memory: 16Mi}, limits: {memory: 64Mi}}
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
- apiVersion: v1
  kind: Service
  metadata:
    name: ${NAME}
    labels: {app.kubernetes.io/managed-by: cert-keeper}
  spec:
    selector: {cert-keeper/name: ${NAME}}
    ports: [{name: http, port: 8080, targetPort: 8080}]
- apiVersion: route.openshift.io/v1
  kind: Route
  metadata:
    name: ${NAME}
    labels: {app.kubernetes.io/managed-by: cert-keeper}
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
  retry "$CLEANUP_WINDOW" "$OC" delete "route/${NAME}" "service/${NAME}" "pod/${NAME}" "networkpolicy/${NAME}" --ignore-not-found --wait=false >/dev/null 2>&1 \
    || echo "::warning title=cert-keeper::could not delete ${NAME}; sweep with: oc delete route,service,pod,networkpolicy -l app.kubernetes.io/managed-by=cert-keeper"
}
trap cleanup EXIT

# Path-based plain-HTTP Route: the router prefers the longer path, so the
# vanity Route (edge + Redirect) keeps serving everything else.
render | "$OC" apply -f - >/dev/null

echo "Waiting up to ${TIMEOUT}s for lego (${CA}) on ${ACME_HOST}"
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
fetch() { "$OC" exec "pod/${NAME}" -c helper -- sh -c "cat \$(ls /data/lego/certificates/*$1 | head -1)" > "$2"; }
retry "$COPY_WINDOW" fetch "${ACME_HOST}.key" "${OUT_DIR}/tls.key" || die "could not copy the private key from ${NAME}."
retry "$COPY_WINDOW" fetch "${ACME_HOST}.crt" "${OUT_DIR}/fullchain.pem" || die "could not copy the certificate from ${NAME}."
retry "$COPY_WINDOW" fetch "${ACME_HOST}.issuer.crt" "${OUT_DIR}/ca.pem" || die "could not copy the issuer chain from ${NAME}."
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
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "### cert-keeper" "" "- host=${ACME_HOST} ca=${CA} notAfter=${not_after}" >> "$GITHUB_STEP_SUMMARY"
echo "Issued ${ACME_HOST} (${CA}), notAfter ${not_after}; PEMs in ${OUT_DIR}"
