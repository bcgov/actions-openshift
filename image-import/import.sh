#!/bin/bash
set -euo pipefail

# $1 = error, $2 = fix. Never put the token in either.
fail() {
  echo "::error::$1"
  echo "Fix: $2"
  exit 1
}

if [ -z "${IMAGE:-}" ]; then
  fail "image is required. Pass a ghcr.io reference with a tag or sha256 digest." "Set image to ghcr.io/<owner>/<name>:<tag>."
fi
if [ -z "${OC_NAMESPACE:-}" ]; then
  fail "oc_namespace is required." "Set oc_namespace to the target namespace, e.g. abc123-dev."
fi
if [[ "${IMAGE}" =~ [[:space:]] ]]; then
  fail "image must not contain whitespace." "Remove spaces and newlines from image."
fi
if [[ "${IMAGE}" != ghcr.io/* ]]; then
  fail "image must be a ghcr.io reference." "Use an image published to GHCR: ghcr.io/<owner>/<name>:<tag>."
fi

ref="${IMAGE#ghcr.io/}"
digest=""
if [[ "${ref}" == *@* ]]; then
  digest="${ref#*@}"
  ref="${ref%%@*}"
  if [[ ! "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    fail "digest must be @sha256: followed by 64 lowercase hex characters." "Copy the full digest, e.g. @sha256:<64 hex>, from the builder digest output."
  fi
fi

tag=""
path="${ref}"
if [[ "${path}" == *:* ]]; then
  tag="${path#*:}"
  path="${path%%:*}"
fi
if [[ "${path}" == *[:@]* ]]; then
  fail "image must contain one tag, one digest, or a tag and a digest." "Use ghcr.io/<owner>/<name>:<tag>, @sha256:<hex>, or :<tag>@sha256:<hex>."
fi
if [ -z "${tag}" ] && [ -z "${digest}" ]; then
  fail "image needs a tag or a sha256 digest." "Append :<tag> or @sha256:<hex> to image."
fi
if [ -n "${tag}" ] && [[ ! "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  fail "tag '${tag}' is not a valid ImageStream tag." "Set tag, or the image tag, to up to 128 letters, digits, '_', '.', or '-', starting with a letter, digit, or '_'."
fi
# OCI name component: alphanumerics, separated by ".", "_", "__", or one or more "-".
if [[ ! "${path}" =~ ^[a-z0-9]+(([.]|_{1,2}|-+)[a-z0-9]+)*(/[a-z0-9]+(([.]|_{1,2}|-+)[a-z0-9]+)*)+$ ]]; then
  fail "image path must be ghcr.io/<owner>/<name> in lowercase." "Lowercase the owner and name, and include both: ghcr.io/<owner>/<name>."
fi

src_tag="${tag}"
stream="${path##*/}"
if [ -n "${NAME:-}" ]; then
  stream="${NAME}"
fi
# DNS-1123 subdomain, which allows repeated internal hyphens.
if [[ ! "${stream}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?([.][a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ ]] || [ "${#stream}" -gt 253 ]; then
  fail "ImageStream name '${stream}' must be a DNS-1123 name." "Set name to lowercase letters, digits, '-', and '.', starting and ending with a letter or digit."
fi
if [ -n "${TAG:-}" ]; then
  tag="${TAG}"
fi
if [ -z "${tag}" ]; then
  tag="${digest#sha256:}"
fi
if [[ ! "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  fail "tag '${tag}' is not a valid ImageStream tag." "Set tag, or the image tag, to up to 128 letters, digits, '_', '.', or '-', starting with a letter, digit, or '_'."
fi

if [ -n "${TOKEN:-}" ]; then
  if [[ "${TOKEN}" =~ [[:space:]] ]]; then
    fail "github_token must not contain whitespace." "Pass the token unchanged, or omit github_token to use the run's token."
  fi
  # Live token in a pull secret scoped to the repository path. Deleted after the import.
  secret="image-import-$(printf '%s' "${path}:${tag}" | sha256sum | cut -c1-20)"
  trap 'oc delete secret "'"${secret}"'" --ignore-not-found >/dev/null' EXIT
  oc delete secret "${secret}" --ignore-not-found >/dev/null
  oc create secret docker-registry "${secret}" \
    --docker-server="ghcr.io/${path}" \
    --docker-username="${ACTOR:-github-actions}" \
    --docker-password="${TOKEN}" \
    --docker-email=unused
fi

echo "Importing ${stream}:${tag} from ${IMAGE}"
oc import-image "${stream}:${tag}" \
  --from="${IMAGE}" \
  --confirm \
  --import-mode=PreserveOriginal \
  --reference-policy=local

# The ImageStream tag must hold the digest GHCR serves: the manifest list digest
# for a multi-arch image. A digest in image is the expected digest.
expected="${digest}"
if [ -z "${expected}" ]; then
  scope="https://ghcr.io/token?scope=repository:${path}:pull&service=ghcr.io"
  if [ -n "${TOKEN:-}" ]; then
    auth="$(printf 'user = "%s:%s"\n' "${ACTOR:-github-actions}" "${TOKEN}" | curl -fsS --retry 3 -K - "${scope}")" || auth=""
  else
    auth="$(curl -fsS --retry 3 "${scope}")" || auth=""
  fi
  bearer="$(sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p' <<< "${auth}")"
  if [ -n "${bearer}" ]; then
    expected="$(printf 'header = "Authorization: Bearer %s"\n' "${bearer}" | curl -fsSI --retry 3 -K - \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
      "https://ghcr.io/v2/${path}/manifests/${src_tag}" \
      | tr -d '\r' | awk 'tolower($0) ~ /^docker-content-digest:/ { sub(/^[^:]*:[ \t]*/, ""); print }')" || expected=""
  fi
  if [[ ! "${expected}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    fail "Could not read the GHCR digest of ${IMAGE}." "Check that the image exists and that github_token can read the package (packages: read), or pin image with @sha256:<digest>."
  fi
fi
actual="$(oc get imagestream "${stream}" -o jsonpath="{.status.tags[?(@.tag==\"${tag}\")].items[0].image}")"
if [ "${actual}" != "${expected}" ]; then
  fail "ImageStream tag ${stream}:${tag} holds '${actual:-no image}', but GHCR serves ${expected} for ${IMAGE}." "Re-run the import. If the GHCR tag moved during the import, pin image with @sha256:<digest>."
fi
echo "Verified ${stream}:${tag} digest ${actual}"

echo "In-cluster pull spec: image-registry.openshift-image-registry.svc:5000/${OC_NAMESPACE}/${stream}:${tag}"
