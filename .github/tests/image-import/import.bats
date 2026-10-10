#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../image-import/import.sh"
  D="${BATS_TEST_TMPDIR}"
  mkdir -p "${D}/bin"
  export OC_LOG="${D}/oc.log"
  : > "${OC_LOG}"
  cat > "${D}/bin/oc" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$OC_LOG"
if [ "${OC_FAIL:-}" = "1" ]; then
  echo "import failed" >&2
  exit 3
fi
exit 0
STUB
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
  import_image "ghcr.io/bcgov/app/backend@sha256:${digest}"
  [ "$status" -eq 0 ]
  [ "$(cat "${OC_LOG}")" = "import-image backend:${digest} --from=ghcr.io/bcgov/app/backend@sha256:${digest} --confirm --import-mode=PreserveOriginal --reference-policy=local" ]
}

@test "tag and digest keeps the tag and pins --from" {
  digest="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
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

@test "token creates a repository pull secret and deletes it" {
  run env \
    PATH="${D}/bin:${PATH}" \
    OC_LOG="${OC_LOG}" \
    OC_NAMESPACE=abc123-prod \
    IMAGE="ghcr.io/bcgov/private-app/backend:1.2.3" \
    TOKEN="test-token" \
    bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  secret="image-import-$(printf '%s' "bcgov/private-app/backend:1.2.3" | sha256sum | cut -c1-20)"
  [ "$(sed -n '1p' "${OC_LOG}")" = "delete secret ${secret} --ignore-not-found" ]
  [ "$(sed -n '2p' "${OC_LOG}")" = "create secret docker-registry ${secret} --docker-server=ghcr.io/bcgov/private-app/backend --docker-username=USERNAME --docker-password=test-token --docker-email=unused" ]
  [ "$(sed -n '3p' "${OC_LOG}")" = "import-image backend:1.2.3 --from=ghcr.io/bcgov/private-app/backend:1.2.3 --confirm --import-mode=PreserveOriginal --reference-policy=local" ]
  [ "$(sed -n '4p' "${OC_LOG}")" = "delete secret ${secret} --ignore-not-found" ]
}

@test "three underscores in a repository component fails" {
  import_image "ghcr.io/acme/team___images/backend:tag"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ghcr.io/<owner>/<name>"* ]]
}
