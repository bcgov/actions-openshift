#!/usr/bin/env bats
# Unit tests for crunchy/scripts/resolve_helm_args.sh; run: bats .github/tests/crunchy

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../crunchy/scripts/resolve_helm_args.sh"
  unset VALUES_URL PVC_SIZE STORAGE_CLASS POSTGRES_VERSION REPLICAS \
    CPU_REQUEST MEMORY_REQUEST ROUTE_ENABLED ROUTE_HOST \
    STANDBY_ENABLED STANDBY_REPO_NAME SHUTDOWN
}

flat() { tr '\n' ' ' <<< "$output" | sed 's/[[:space:]]*$//'; }


@test "no overrides: emits nothing, bundled values apply" {
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "route_enabled=false: emits nothing" {
  ROUTE_ENABLED=false run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sizing overrides propagate" {
  PVC_SIZE=500Mi STORAGE_CLASS=netapp-file-standard REPLICAS=3 CPU_REQUEST=100m MEMORY_REQUEST=256Mi run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(flat)" == *"--set-string crunchy.instances.dataVolumeClaimSpec.storage=500Mi"* ]]
  [[ "$(flat)" == *"--set-string crunchy.instances.dataVolumeClaimSpec.storageClassName=netapp-file-standard"* ]]
  [[ "$(flat)" == *"--set crunchy.instances.replicas=3"* ]]
  [[ "$(flat)" == *"--set-string crunchy.instances.requests.cpu=100m"* ]]
  [[ "$(flat)" == *"--set-string crunchy.instances.requests.memory=256Mi"* ]]
}

@test "postgres_version lookup: image and PostGIS per version" {
  for pair in 15:ubi9-15.15-3.3-2547:3.3 16:ubi9-16.11-3.4-2547:3.4 17:ubi9-17.7-3.6-2547:3.6 18:ubi9-18.1-3.6-2547:3.6; do
    IFS=: read -r version tag gis <<< "$pair"
    POSTGRES_VERSION="$version" run "${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$(flat)" == *"--set crunchy.postgresVersion=${version}"* ]]
    [[ "$(flat)" == *"crunchy.image=artifacts.developer.gov.bc.ca/bcgov-docker-local/crunchy-postgres-gis:${tag}"* ]]
    [[ "$(flat)" == *"--set-string crunchy.postGISVersion=${gis}"* ]]
  done
}

@test "postgres_version: unsupported values fail" {
  for version in 14 19 banana; do
    POSTGRES_VERSION="$version" run "${SCRIPT}"
    [ "$status" -eq 1 ]
    [[ "$(flat)" == *"Unsupported postgres_version '${version}'"* ]]
  done
}

@test "invalid values fail" {
  PVC_SIZE="1Gi --set x=y" run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$(flat)" == *"pvc_size"* ]]
  REPLICAS=0 run "${SCRIPT}"
  [ "$status" -eq 1 ]
  CPU_REQUEST=lots run "${SCRIPT}"
  [ "$status" -eq 1 ]
  MEMORY_REQUEST=1,2 run "${SCRIPT}"
  [ "$status" -eq 1 ]
  STORAGE_CLASS=Bad_Class run "${SCRIPT}"
  [ "$status" -eq 1 ]
  ROUTE_ENABLED=yes run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$(flat)" == *"route_enabled must be"* ]]
  ROUTE_ENABLED=true ROUTE_HOST="db.example.com,x" run "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "values_file alone: emits nothing" {
  VALUES_URL=https://example.com/values.yml run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "values_file conflicts with every override input" {
  for var in PVC_SIZE=1Gi STORAGE_CLASS=netapp-block-standard POSTGRES_VERSION=17 REPLICAS=3 \
    CPU_REQUEST=50m MEMORY_REQUEST=128Mi ROUTE_ENABLED=true ROUTE_HOST=db.example.com \
    STANDBY_ENABLED=true STANDBY_REPO_NAME=repo1 SHUTDOWN=true; do
    run env VALUES_URL=https://example.com/values.yml "$var" "${SCRIPT}"
    [ "$status" -eq 1 ]
    name="${var%%=*}"
    [[ "$(flat)" == *"values_file cannot be combined with override inputs (${name,,})"* ]]
  done
}

@test "values_file conflict lists every offending input" {
  VALUES_URL=https://example.com/values.yml PVC_SIZE=1Gi REPLICAS=3 run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$(flat)" == *"(pvc_size replicas)"* ]]
}

@test "route: enabled with and without host" {
  ROUTE_ENABLED=true run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(flat)" = "--set route.enabled=true" ]
  ROUTE_ENABLED=true ROUTE_HOST=db.example.com run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(flat)" == *"--set-string route.host=db.example.com"* ]]
  [ "$(echo "$output" | wc -l)" -eq 4 ]
}

@test "route: host without route_enabled fails" {
  ROUTE_HOST=db.example.com run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$(flat)" == *"route_host requires route_enabled"* ]]
}

@test "standby: enables with default repo2" {
  STANDBY_ENABLED=true run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(flat)" == *"--set crunchy.standby.enabled=true"* ]]
  [[ "$(flat)" == *"--set-string crunchy.standby.repoName=repo2"* ]]
}

@test "standby: custom repo name" {
  STANDBY_ENABLED=true STANDBY_REPO_NAME=repo1 run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(flat)" == *"--set-string crunchy.standby.repoName=repo1"* ]]
}

@test "shutdown: sets crunchy.shutdown" {
  SHUTDOWN=true run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(flat)" = "--set crunchy.shutdown=true" ]
}

@test "standby_repo_name must match repo1-repo4" {
  STANDBY_ENABLED=true STANDBY_REPO_NAME='repo2 --set crunchy.shutdown=true' run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$(flat)" == *"standby_repo_name must match"* ]]
}

@test "values_file conflicts with non-default standby_repo_name" {
  VALUES_URL=https://example.com/values.yml STANDBY_REPO_NAME=repo1 run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$(flat)" == *"standby_repo_name"* ]]
}

@test "values_file allows default standby_repo_name repo2" {
  VALUES_URL=https://example.com/values.yml STANDBY_REPO_NAME=repo2 run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "standby_enabled must be true or false" {
  STANDBY_ENABLED=yes run "${SCRIPT}"
  [ "$status" -eq 1 ]
}
