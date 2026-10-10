#!/usr/bin/env bash
# Builds the pg-upgrade test matrix from Docker Hub tags, so a new PostgreSQL major is tested
# the day its image is published, with no pin to bump.
#   SOURCES: every source major the action supports
#   GOLDEN:  bcgov/quickstart-openshift's major, the usual upgrade target
#   NEWEST:  the highest major tag of the official postgres image (found here)
# Writes containers=<json> and cluster=<json> to $GITHUB_OUTPUT. TAGS_DIR=<dir> reads
# <dir>/postgres.json and <dir>/postgis-<major>.json instead of Docker Hub (tests).
set -euo pipefail

fail() {
  echo "::error::$1"
  if [ -n "${2:-}" ]; then echo "Fix: $2"; fi
  exit 1
}

SOURCES="${SOURCES:-13 14 15 16 17}"
GOLDEN="${GOLDEN:-17}"
HUB=https://hub.docker.com/v2/repositories

tags() { # file-name url -> tag names
  local json
  if [ -n "${TAGS_DIR:-}" ]; then
    json="$(cat "${TAGS_DIR}/$1.json")" || return 1
  else
    json="$(curl -fsS --retry 3 --retry-all-errors --max-time 30 "$2")" || return 1
  fi
  jq -r '.results[].name' <<< "$json"
}

NEWEST="$(tags postgres "${HUB}/library/postgres/tags?page_size=100&ordering=last_updated" | grep -E '^[0-9]+$' | sort -n | tail -n 1)" \
  || fail "Could not read postgres tags from Docker Hub." "Re-run the job; Docker Hub may be rate limiting this runner."
[ -n "$NEWEST" ] && [ "$NEWEST" -ge "$GOLDEN" ] || fail "Newest postgres major '${NEWEST}' is below GOLDEN ${GOLDEN}." "Check Docker Hub's postgres tags, or GOLDEN in this script."

# Newest postgis/postgis:<major>-<x.y> tag for a major, or empty
gis() {
  tags "postgis-$1" "${HUB}/postgis/postgis/tags?page_size=100&name=$1-" | grep -E "^$1-[0-9]+\.[0-9]+$" | sort -V | tail -n 1 || true
}

declare -A GIS
for m in $SOURCES $GOLDEN $NEWEST; do
  [ -n "${GIS[$m]+x}" ] || GIS[$m]="$(gis "$m")"
  [ -n "${GIS[$m]}" ] || [ "$m" = "$NEWEST" ] || fail "No postgis/postgis:${m}-<x.y> tag on Docker Hub." "Check the postgis/postgis tags; drop ${m} from SOURCES if it is no longer published."
done
GIS_NEWEST="$NEWEST"
if [ -z "${GIS[$NEWEST]}" ]; then
  # PostGIS images follow a PostgreSQL release by days to weeks; test the newest one they have
  GIS_NEWEST=$((NEWEST - 1))
  echo "::notice::postgis/postgis has no ${NEWEST} image yet; PostGIS pairs target ${GIS_NEWEST} until it does."
  [ -n "${GIS[$GIS_NEWEST]+x}" ] || GIS[$GIS_NEWEST]="$(gis "$GIS_NEWEST")"
fi

CONTAINERS="$(
  for t in $(printf '%s\n' "$GOLDEN" "$NEWEST" | sort -nu); do
    gt="$t"
    [ "$t" != "$NEWEST" ] || gt="$GIS_NEWEST"
    for s in $SOURCES; do
      [ "$s" -lt "$t" ] || continue
      gis_new=""
      [ "$s" -ge "$gt" ] || gis_new="postgis/postgis:${GIS[$gt]}"
      jq -nc --arg name "${s} → ${t}" --arg pg_old "postgres:${s}" --arg pg_new "postgres:${t}" \
        --arg gis_old "postgis/postgis:${GIS[$s]}" --arg gis_new "$gis_new" \
        '{name: $name, pg_old: $pg_old, pg_new: $pg_new, gis_old: $gis_old, gis_new: $gis_new}'
    done
  done | jq -sc '{include: .}'
)"

# Representative cluster subset: the oldest source to the golden path with the full cycle on
# small data, and PostGIS from the oldest source to the newest major on a large dataset
OLDEST="$(tr ' ' '\n' <<< "$SOURCES" | sort -n | head -n 1)"
CLUSTER="$(jq -nc --arg o "$OLDEST" --arg g "$GOLDEN" --arg go "${GIS[$OLDEST]}" --arg gn "${GIS[$GIS_NEWEST]}" '{include: [
  {id: "pg", name: ("postgres " + $o + " → " + $g + ", small"), old: ("postgres:" + $o), new: ("postgres:" + $g), data: "small"},
  {id: "gis", name: ("postgis " + $go + " → " + $gn + ", large"), old: ("postgis/postgis:" + $go), new: ("postgis/postgis:" + $gn), data: "large"}]}')"

echo "Newest postgres major: ${NEWEST}; golden path: ${GOLDEN}; PostGIS newest: ${GIS[$GIS_NEWEST]}"
jq -r '.include[] | "  containers: " + .name + " (" + .pg_old + " → " + .pg_new + (if .gis_new != "" then "; " + .gis_old + " → " + .gis_new else "" end) + ")"' <<< "$CONTAINERS"
jq -r '.include[] | "  cluster: " + .name' <<< "$CLUSTER"
{
  echo "containers=${CONTAINERS}"
  echo "cluster=${CLUSTER}"
  echo "newest=${NEWEST}"
} >> "${GITHUB_OUTPUT:-/dev/null}"
