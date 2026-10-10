#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../image-import/import.sh"
  D="${BATS_TEST_TMPDIR}"
  mkdir -p "${D}/bin"
  export OC_LOG="${D}/oc.log" OC_GET_LOG="${D}/oc-get.log" CURL_LOG="${D}/curl.log"
  : > "${OC_LOG}"; : > "${OC_GET_LOG}"; : > "${CURL_LOG}"
  export GHCR_DIGEST="sha256:$(printf 'c%.0s' {1..64})"
  export IS_DIGEST="${GHCR_DIGEST}"
  cat > "${D}/bin/oc" << 'STUB'
#!/bin/bash
if [ "$1" = "get" ]; then
  printf '%s\n' "$*" >> "$OC_GET_LOG"
  printf '%s' "${IS_DIGEST}"
  exit 0
fi
printf '%s\n' "$*" >> "$OC_LOG"
if [ "${OC_FAIL:-}" = "1" ]; then
  echo "import failed" >&2
  exit 3
fi
exit 0
STUB
  # GHCR: the token endpoint returns a bearer token, a manifest HEAD returns the digest
  cat > "${D}/bin/curl" << 'STUB'
#!/bin/bash
config=""
for a in "$@"; do [ "$a" = "-" ] && config="$(cat)"; done
printf '%s | %s\n' "$*" "${config}" >> "$CURL_LOG"
case "$*" in
  *ghcr.io/token*) printf '{"token":"bearer-1"}' ;;
  *ghcr.io/v2/*) printf 'HTTP/2 200\r\ndocker-content-digest: %s\r\n\r\n' "${GHCR_DIGEST}" ;;
  *) exit 22 ;;
esac
STUB
  chmod +x "${D}/bin/curl"
  chmod +x "${D}/bin/oc"
}

import_image() {
  run env \
    PATH="${D}/bin:${PATH}" \
    OC_LOG="${OC_LOG}" \
    OC_NAMESPACE="${OC_NAMESPACE:-abc123-prod}" \
    IMAGE="$1" \
    bash "${SCRIPT}"
}

@test "tagged reference imports that tag with a local manifest list" {
  import_image "ghcr.io/bcgov/quickstart-openshift/backend:pr-42"
  [ "$status" -eq 0 ]
  [ "$(cat "${OC_LOG}")" = "import-image backend:pr-42 --from=ghcr.io/bcgov/quickstart-openshift/backend:pr-42 --confirm --import-mode=PreserveOriginal --reference-policy=local" ]
  [[ "$output" == *"image-registry.openshift-image-registry.svc:5000/abc123-prod/backend:pr-42"* ]]
}

@test "digest without a tag uses the hex as the ImageStream tag" {
  digest="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  IS_DIGEST="sha256:${digest}"
  import_image "ghcr.io/bcgov/app/backend@sha256:${digest}"
  [ "$status" -eq 0 ]
  [ "$(cat "${OC_LOG}")" = "import-image backend:${digest} --from=ghcr.io/bcgov/app/backend@sha256:${digest} --confirm --import-mode=PreserveOriginal --reference-policy=local" ]
}

@test "tag and digest keeps the tag and pins --from" {
  digest="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  IS_DIGEST="sha256:${digest}"
  import_image "ghcr.io/bcgov/app/backend:pr-7@sha256:${digest}"
  [ "$status" -eq 0 ]
  [ "$(cat "${OC_LOG}")" = "import-image backend:pr-7 --from=ghcr.io/bcgov/app/backend:pr-7@sha256:${digest} --confirm --import-mode=PreserveOriginal --reference-policy=local" ]
}

@test "oc failure fails the script" {
  OC_FAIL=1 import_image "ghcr.io/bcgov/app/backend:latest"
  [ "$status" -eq 3 ]
}

@test "missing tag and digest fails" {
  import_image "ghcr.io/bcgov/app/backend"
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs a tag or a sha256 digest"* ]]
}

@test "non-ghcr reference fails" {
  import_image "docker.io/library/nginx:1.27"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ghcr.io"* ]]
}

@test "short digest fails" {
  import_image "ghcr.io/bcgov/app/backend@sha256:abc"
  [ "$status" -eq 1 ]
  [[ "$output" == *"64 lowercase hex"* ]]
}

@test "ImageStream name with an underscore fails" {
  import_image "ghcr.io/bcgov/app/my_backend:latest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DNS-1123"* ]]
}

@test "repeated hyphens and a double underscore are valid repository components" {
  import_image "ghcr.io/acme/team--images/backend:tag"
  [ "$status" -eq 0 ]
  [[ "$(cat "${OC_LOG}")" == import-image\ backend:tag\ --from=ghcr.io/acme/team--images/backend:tag\ * ]]
  : > "${OC_LOG}"
  import_image "ghcr.io/acme/team__images/backend:tag"
  [ "$status" -eq 0 ]
  [[ "$(cat "${OC_LOG}")" == import-image\ backend:tag\ --from=ghcr.io/acme/team__images/backend:tag\ * ]]
}

@test "repeated hyphens are a valid ImageStream name" {
  import_image "ghcr.io/acme/my--backend:tag"
  [ "$status" -eq 0 ]
  [[ "$(cat "${OC_LOG}")" == import-image\ my--backend:tag\ * ]]
}

@test "name and tag override the ImageStream destination" {
  run env \
    PATH="${D}/bin:${PATH}" \
    OC_LOG="${OC_LOG}" \
    OC_NAMESPACE=abc123-prod \
    IMAGE="ghcr.io/bcgov/quickstart-openshift/backend:latest" \
    NAME="image-import" \
    TAG="100" \
    bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(cat "${OC_LOG}")" = "import-image image-import:100 --from=ghcr.io/bcgov/quickstart-openshift/backend:latest --confirm --import-mode=PreserveOriginal --reference-policy=local" ]
}

@test "token creates a repository pull secret as the actor and deletes it" {
  run env \
    PATH="${D}/bin:${PATH}" \
    OC_LOG="${OC_LOG}" \
    OC_NAMESPACE=abc123-prod \
    IMAGE="ghcr.io/bcgov/private-app/backend:1.2.3" \
    TOKEN="test-token" \
    ACTOR="octocat" \
    bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  secret="image-import-$(printf '%s' "bcgov/private-app/backend:1.2.3" | sha256sum | cut -c1-20)"
  [ "$(sed -n '1p' "${OC_LOG}")" = "delete secret ${secret} --ignore-not-found" ]
  [ "$(sed -n '2p' "${OC_LOG}")" = "create secret docker-registry ${secret} --docker-server=ghcr.io/bcgov/private-app/backend --docker-username=octocat --docker-password=test-token --docker-email=unused" ]
  [ "$(sed -n '3p' "${OC_LOG}")" = "import-image backend:1.2.3 --from=ghcr.io/bcgov/private-app/backend:1.2.3 --confirm --import-mode=PreserveOriginal --reference-policy=local" ]
  [ "$(sed -n '4p' "${OC_LOG}")" = "delete secret ${secret} --ignore-not-found" ]
}

@test "three underscores in a repository component fails" {
  import_image "ghcr.io/acme/team___images/backend:tag"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ghcr.io/<owner>/<name>"* ]]
}

@test "every invalid input prints a Fix line" {
  for image in "" "docker.io/library/nginx:1.27" "ghcr.io/bcgov/app/backend" \
    "ghcr.io/bcgov/app/backend@sha256:abc" "ghcr.io/bcgov/app/my_backend:latest" \
    "ghcr.io/bcgov/App/backend:latest" "ghcr.io/bcgov/app/backend:-bad"; do
    import_image "${image}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::"* ]]
    [[ "$output" == *"Fix: "* ]]
  done
  [ ! -s "${OC_LOG}" ]
}

@test "digest pin is the expected digest and skips the GHCR lookup" {
  digest="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  IS_DIGEST="sha256:${digest}"
  import_image "ghcr.io/bcgov/app/backend:pr-7@sha256:${digest}"
  [ "$status" -eq 0 ]
  [ ! -s "${CURL_LOG}" ]
  [[ "$output" == *"Verified backend:pr-7 digest sha256:${digest}"* ]]
}

@test "matching digest asks GHCR for the manifest list and passes" {
  import_image "ghcr.io/bcgov/quickstart-openshift/backend:pr-42"
  [ "$status" -eq 0 ]
  grep -q 'ghcr.io/token?scope=repository:bcgov/quickstart-openshift/backend:pull' "${CURL_LOG}"
  grep -q 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' "${CURL_LOG}"
  grep -q 'https://ghcr.io/v2/bcgov/quickstart-openshift/backend/manifests/pr-42 | header = "Authorization: Bearer bearer-1"' "${CURL_LOG}"
  [ "$(cat "${OC_GET_LOG}")" = 'get imagestream backend -o jsonpath={.status.tags[?(@.tag=="pr-42")].items[0].image}' ]
  [[ "$output" == *"Verified backend:pr-42 digest ${GHCR_DIGEST}"* ]]
}

@test "GHCR lookup uses the source tag when tag overrides the destination" {
  run env PATH="${D}/bin:${PATH}" OC_NAMESPACE=abc123-prod \
    IMAGE="ghcr.io/bcgov/quickstart-openshift/backend:latest" NAME=image-import TAG=100 \
    bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -q 'manifests/latest |' "${CURL_LOG}"
  grep -q 'tag=="100"' "${OC_GET_LOG}"
}

@test "token authenticates the GHCR digest lookup as the actor" {
  run env PATH="${D}/bin:${PATH}" OC_NAMESPACE=abc123-prod \
    IMAGE="ghcr.io/bcgov/private-app/backend:1.2.3" TOKEN=test-token ACTOR=octocat \
    bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -q 'ghcr.io/token?scope=repository:bcgov/private-app/backend:pull.* | user = "octocat:test-token"' "${CURL_LOG}"
}

@test "digest mismatch after the import fails with a Fix line" {
  IS_DIGEST="sha256:$(printf 'e%.0s' {1..64})"
  import_image "ghcr.io/bcgov/app/backend:latest"
  [ "$status" -eq 1 ]
  grep -q '^import-image ' "${OC_LOG}"
  [[ "$output" == *"::error::ImageStream tag backend:latest holds '${IS_DIGEST}', but GHCR serves ${GHCR_DIGEST}"* ]]
  [[ "$output" == *"Fix: "* ]]
  [[ "$output" != *"Verified"* ]]
}

@test "empty ImageStream digest fails" {
  IS_DIGEST=""
  import_image "ghcr.io/bcgov/app/backend:latest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds 'no image'"* ]]
  [[ "$output" == *"Fix: "* ]]
}

@test "unreadable GHCR digest fails with a Fix line" {
  GHCR_DIGEST="not-a-digest"
  import_image "ghcr.io/bcgov/app/backend:latest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::Could not read the GHCR digest of ghcr.io/bcgov/app/backend:latest."* ]]
  [[ "$output" == *"Fix: "* ]]
}
