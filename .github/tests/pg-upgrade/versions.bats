#!/usr/bin/env bats
# .github/tests/pg-upgrade/versions.sh with Docker Hub tag lists from files

setup() {
  export SCRIPT="${BATS_TEST_DIRNAME}/versions.sh"
  export TAGS_DIR="${BATS_TEST_TMPDIR}/tags" GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
  mkdir -p "$TAGS_DIR"
  : > "$GITHUB_OUTPUT"
  tags() { # file tag...
    local f="$1"
    shift
    printf '%s\n' "$@" | jq -R . | jq -sc '{results: map({name: ., images: [{os: "linux", architecture: "amd64", status: "active"}]})}' > "${TAGS_DIR}/${f}.json"
  }
  tags postgres 18 18.0 17 17.6 16 latest 19beta1 18-bookworm
  for m in 13 14 15 16; do tags "postgis-$m" "$m-3.4" "$m-3.5" "$m-3.5-alpine"; done
  tags postgis-17 17-3.4 17-3.5
  tags postgis-18 18-3.6
}

out() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT"; }

@test "newest major comes from the tags; every source upgrades to golden and newest" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out newest)" = 18 ]
  [ "$(out containers | jq -r '[.include[].name] | join(",")')" = "13 → 17,14 → 17,15 → 17,16 → 17,13 → 18,14 → 18,15 → 18,16 → 18,17 → 18" ]
  [ "$(out containers | jq -r '.include[] | select(.name == "17 → 18") | .gis_old + " " + .gis_new')" = "postgis/postgis:17-3.5 postgis/postgis:18-3.6" ]
}

@test "a new major is picked up with no pin to bump" {
  tags postgres 19 18 17
  tags postgis-19 19-3.6
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out newest)" = 19 ]
  out containers | jq -e '.include[] | select(.name == "13 → 19" and .gis_new == "postgis/postgis:19-3.6")'
}

@test "PostGIS pairs wait for a PostGIS image of a brand-new major" {
  tags postgres 19 18 17
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"postgis/postgis has no 19 image yet"* ]]
  [ "$(out containers | jq -r '.include[] | select(.name == "13 → 19") | .pg_new + " " + .gis_new')" = "postgres:19 postgis/postgis:18-3.6" ]
  # 18 → 19 has no PostGIS pair: nothing newer than 18 to go to
  [ "$(out containers | jq -r '.include[] | select(.name == "18 → 19") | .gis_new')" = "" ]
}

@test "unreadable tags fail with a Fix line" {
  rm "${TAGS_DIR}/postgres.json"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::Could not read postgres tags"* ]]
  [[ "$output" == *"Fix: "* ]]
}

@test "a source major with no PostGIS image fails with a Fix line" {
  tags postgis-14 latest
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No postgis/postgis:14-<x.y> tag"* ]]
}

@test "tags without an active linux/amd64 image are ignored" {
  cat > "${TAGS_DIR}/postgres.json" <<'JSON'
{"results":[
  {"name":"21","images":[{"os":"linux","architecture":"amd64","status":"inactive"}]},
  {"name":"20","images":[{"os":"linux","architecture":"arm64","status":"active"}]},
  {"name":"19","images":[]},
  {"name":"18","images":[{"os":"linux","architecture":"amd64","status":"active"}]},
  {"name":"17","images":[{"os":"linux","architecture":"amd64","status":"active"}]}
]}
JSON
  cat > "${TAGS_DIR}/postgis-18.json" <<'JSON'
{"results":[
  {"name":"18-3.7","images":[]},
  {"name":"18-3.6","images":[{"os":"linux","architecture":"amd64","status":"active"}]}
]}
JSON
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out newest)" = 18 ]
  [ "$(out containers | jq -r '.include[] | select(.name == "17 → 18") | .gis_new')" = "postgis/postgis:18-3.6" ]
}
