#!/usr/bin/env bash
# Sizes the large-dataset cluster test to the namespace: reads ResourceQuota and LimitRange JSON
# (from oc get ... -o json, run by the workflow through oc-runner) and prints the dataset scale.
# Scale 1 is about 450 MB on disk per database and 750 MB in the Job (dump plus rehearsal copy).
#   quota.sh <resourcequota.json> <limitrange.json>  ->  stdout: scale; stderr: the numbers
# Env: MAX_SCALE (default 2), DB_MEMORY_MI (each of 2 database pods), JOB_MEMORY_MI.
set -euo pipefail

fail() {
  echo "::error::$1" >&2
  if [ -n "${2:-}" ]; then echo "Fix: $2" >&2; fi
  exit 1
}

QUOTA="${1:?resourcequota json}"
LIMITS="${2:?limitrange json}"
MAX_SCALE="${MAX_SCALE:-2}"
DB_MEMORY_MI="${DB_MEMORY_MI:-512}"
JOB_MEMORY_MI="${JOB_MEMORY_MI:-1024}"
MI=1048576
JOB_PER_SCALE=$((750 * MI))
DB_PER_SCALE=$((450 * MI))

# Kubernetes quantities to bytes (or plain counts)
JQ_BYTES='def bytes: tostring | capture("^(?<n>[0-9.]+)(?<u>[a-zA-Z]*)$")
  | (.n | tonumber) * ({"": 1, "m": 0.001, "k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
      "Ki": 1024, "Mi": 1048576, "Gi": 1073741824, "Ti": 1099511627776}[.u] // error("unit " + .u));'
# Smallest headroom (hard - used) for a quota key across every ResourceQuota, or -1 if none sets it
free() {
  jq -r "${JQ_BYTES}"' [.items[].status | select(.hard[$k] != null) | (.hard[$k] | bytes) - ((.used[$k] // "0") | bytes)]
    | if length == 0 then -1 else (min | floor) end' --arg k "$1" "$QUOTA"
}
# Smallest default (or max) container limit for a resource across LimitRanges, or -1
limit() {
  jq -r "${JQ_BYTES}"' [.items[].spec.limits[] | select(.type == "Container") | (.default[$k] // .max[$k]) | select(. != null) | bytes]
    | if length == 0 then -1 else (min | floor) end' --arg k "$1" "$LIMITS"
}

jq -e '.items' "$QUOTA" > /dev/null 2>&1 || fail "Could not read the namespace ResourceQuota." "Re-run the job; the deploy token needs to read resourcequotas."
jq -e '.items' "$LIMITS" > /dev/null 2>&1 || fail "Could not read the namespace LimitRange." "Re-run the job; the deploy token needs to read limitranges."

PODS="$(free pods)"
P2="$(free count/pods)"
if [ "$PODS" = -1 ] || { [ "$P2" != -1 ] && [ "$P2" -lt "$PODS" ]; }; then PODS="$P2"; fi
MEM_LIMITS="$(free limits.memory)"
EPH_FREE="$(free limits.ephemeral-storage)"
EPH_LIMIT="$(limit ephemeral-storage)"
NEED_MEM=$(((2 * DB_MEMORY_MI + JOB_MEMORY_MI) * MI))

echo "Quota headroom: pods ${PODS}, limits.memory $((MEM_LIMITS < 0 ? -1 : MEM_LIMITS / MI))Mi, limits.ephemeral-storage $((EPH_FREE < 0 ? -1 : EPH_FREE / MI))Mi (-1 = no quota)" >&2
echo "Container ephemeral-storage limit from LimitRange: $((EPH_LIMIT < 0 ? -1 : EPH_LIMIT / MI))Mi (-1 = none)" >&2

[ "$PODS" = -1 ] || [ "$PODS" -ge 3 ] || fail "The namespace has room for ${PODS} more pod(s); the test needs 3." "Wait for other PR environments to close, or clean up leftovers, then re-run."
[ "$MEM_LIMITS" = -1 ] || [ "$MEM_LIMITS" -ge "$NEED_MEM" ] \
  || fail "The namespace has $((MEM_LIMITS / MI))Mi of memory limits free; the test needs $((NEED_MEM / MI))Mi." "Wait for other PR environments to close, or clean up leftovers, then re-run."

SCALE="$MAX_SCALE"
# Keep within 80% of what one container may write (the Job holds the most) and of the quota
if [ "$EPH_LIMIT" != -1 ]; then
  s=$((EPH_LIMIT * 8 / 10 / JOB_PER_SCALE))
  [ "$s" -ge "$SCALE" ] || SCALE="$s"
fi
if [ "$EPH_FREE" != -1 ]; then
  s=$((EPH_FREE * 8 / 10 / (JOB_PER_SCALE + 2 * DB_PER_SCALE)))
  [ "$s" -ge "$SCALE" ] || SCALE="$s"
fi
[ "$SCALE" -ge 1 ] || fail "The namespace's ephemeral storage is too small for the large dataset (scale 1 needs about $((JOB_PER_SCALE / MI))Mi per container, $(((JOB_PER_SCALE + 2 * DB_PER_SCALE) / MI))Mi in total)." "Raise the namespace's ephemeral-storage limits, or wait for other PR environments to close, then re-run."
echo "Dataset scale ${SCALE} (about $((SCALE * DB_PER_SCALE / MI))Mi per database)" >&2
echo "$SCALE"
