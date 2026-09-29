#!/bin/bash
#
# Resolves Helm --set arguments for the crunchy chart from override inputs.
# Validates input and prints the arguments to stdout; errors go to stderr.
# No side effects (no cd, helm, oc or curl), so it can be unit tested.
#
# Env vars (all optional):
#   VALUES_URL        Set when the caller supplied values_file. Overrides are
#                     then rejected: the values file owns every setting.
#   PVC_SIZE          crunchy.instances.dataVolumeClaimSpec.storage
#   STORAGE_CLASS     crunchy.instances.dataVolumeClaimSpec.storageClassName
#   POSTGRES_VERSION  15, 16, 17 or 18; sets postgresVersion, image, postGISVersion
#   REPLICAS          crunchy.instances.replicas
#   CPU_REQUEST       crunchy.instances.requests.cpu
#   MEMORY_REQUEST    crunchy.instances.requests.memory
#   ROUTE_ENABLED     true or false; true renders the TLS passthrough Route
#   ROUTE_HOST        Route host; requires ROUTE_ENABLED=true
#
# Unset overrides emit nothing, so the values file (bundled or custom) applies.

set -euo pipefail

VALUES_URL="${VALUES_URL:-}"
PVC_SIZE="${PVC_SIZE:-}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
POSTGRES_VERSION="${POSTGRES_VERSION:-}"
REPLICAS="${REPLICAS:-}"
CPU_REQUEST="${CPU_REQUEST:-}"
MEMORY_REQUEST="${MEMORY_REQUEST:-}"
ROUTE_ENABLED="${ROUTE_ENABLED:-false}"
ROUTE_HOST="${ROUTE_HOST:-}"

fail() {
  echo "Error: $*" >&2
  exit 1
}

if [ "${ROUTE_ENABLED}" != "true" ] && [ "${ROUTE_ENABLED}" != "false" ]; then
  fail "route_enabled must be 'true' or 'false', got '${ROUTE_ENABLED}'."
fi

# values_file and override inputs are mutually exclusive
if [ -n "${VALUES_URL}" ]; then
  CONFLICTS=()
  for var in PVC_SIZE STORAGE_CLASS POSTGRES_VERSION REPLICAS CPU_REQUEST MEMORY_REQUEST ROUTE_HOST; do
    if [ -n "${!var}" ]; then
      CONFLICTS+=("${var,,}")
    fi
  done
  if [ "${ROUTE_ENABLED}" = "true" ]; then
    CONFLICTS+=("route_enabled")
  fi
  if [ "${#CONFLICTS[@]}" -gt 0 ]; then
    fail "values_file cannot be combined with override inputs (${CONFLICTS[*]}). Move those settings into the values file, or drop values_file."
  fi
  exit 0
fi

# Kubernetes quantity, e.g. 150Mi, 1Gi, 50m, 0.5
QUANTITY='^[0-9]+(\.[0-9]+)?(m|k|Ki|M|Mi|G|Gi|T|Ti|P|Pi|E|Ei)?$'
DNS_LABEL='[a-z0-9]([-a-z0-9]*[a-z0-9])?'

ARGS=()
if [ -n "${PVC_SIZE}" ]; then
  [[ "${PVC_SIZE}" =~ ${QUANTITY} ]] || fail "pvc_size '${PVC_SIZE}' is not a valid quantity (e.g. 150Mi, 1Gi)."
  ARGS+=(--set-string "crunchy.instances.dataVolumeClaimSpec.storage=${PVC_SIZE}")
fi
if [ -n "${STORAGE_CLASS}" ]; then
  [[ "${STORAGE_CLASS}" =~ ^${DNS_LABEL}(\.${DNS_LABEL})*$ ]] || fail "storage_class '${STORAGE_CLASS}' is not a valid name."
  ARGS+=(--set-string "crunchy.instances.dataVolumeClaimSpec.storageClassName=${STORAGE_CLASS}")
fi
if [ -n "${POSTGRES_VERSION}" ]; then
  # Known-good GIS images for Crunchy Operator 5.8.5:
  # https://github.com/bcgov/crunchy-postgres#current-compatible-images
  case "${POSTGRES_VERSION}" in
    15) IMAGE_TAG="ubi9-15.15-3.3-2547"; POSTGIS_VERSION="3.3" ;;
    16) IMAGE_TAG="ubi9-16.11-3.4-2547"; POSTGIS_VERSION="3.4" ;;
    17) IMAGE_TAG="ubi9-17.7-3.6-2547"; POSTGIS_VERSION="3.6" ;;
    18) IMAGE_TAG="ubi9-18.1-3.6-2547"; POSTGIS_VERSION="3.6" ;;
    *) fail "Unsupported postgres_version '${POSTGRES_VERSION}'. Supported: 15, 16, 17, 18. For anything else, use values_file and set crunchy.image and crunchy.postGISVersion." ;;
  esac
  ARGS+=(--set "crunchy.postgresVersion=${POSTGRES_VERSION}")
  ARGS+=(--set-string "crunchy.image=artifacts.developer.gov.bc.ca/bcgov-docker-local/crunchy-postgres-gis:${IMAGE_TAG}")
  ARGS+=(--set-string "crunchy.postGISVersion=${POSTGIS_VERSION}")
fi
if [ -n "${REPLICAS}" ]; then
  [[ "${REPLICAS}" =~ ^[1-9][0-9]*$ ]] || fail "replicas '${REPLICAS}' must be a positive integer."
  ARGS+=(--set "crunchy.instances.replicas=${REPLICAS}")
fi
if [ -n "${CPU_REQUEST}" ]; then
  [[ "${CPU_REQUEST}" =~ ${QUANTITY} ]] || fail "cpu_request '${CPU_REQUEST}' is not a valid quantity (e.g. 50m)."
  ARGS+=(--set-string "crunchy.instances.requests.cpu=${CPU_REQUEST}")
fi
if [ -n "${MEMORY_REQUEST}" ]; then
  [[ "${MEMORY_REQUEST}" =~ ${QUANTITY} ]] || fail "memory_request '${MEMORY_REQUEST}' is not a valid quantity (e.g. 128Mi)."
  ARGS+=(--set-string "crunchy.instances.requests.memory=${MEMORY_REQUEST}")
fi
if [ "${ROUTE_ENABLED}" = "true" ]; then
  ARGS+=(--set "route.enabled=true")
fi
if [ -n "${ROUTE_HOST}" ]; then
  [ "${ROUTE_ENABLED}" = "true" ] || fail "route_host requires route_enabled: true."
  [[ "${ROUTE_HOST}" =~ ^${DNS_LABEL}(\.${DNS_LABEL})*$ ]] || fail "route_host '${ROUTE_HOST}' is not a valid host name."
  ARGS+=(--set-string "route.host=${ROUTE_HOST}")
fi

# Validated values contain no whitespace, so callers can word-split the output
echo "${ARGS[*]}"
