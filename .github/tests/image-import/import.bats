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
