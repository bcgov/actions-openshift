#!/bin/bash
set -euo pipefail

if [ -z "${IMAGE:-}" ]; then
  echo "::error::image is required. Pass a ghcr.io reference with a tag or sha256 digest."
  exit 1
fi
if [ -z "${OC_NAMESPACE:-}" ]; then
  echo "::error::oc_namespace is required."
  exit 1
fi
if [[ "${IMAGE}" =~ [[:space:]] ]]; then
  echo "::error::image must not contain whitespace."
  exit 1
fi
if [[ "${IMAGE}" != ghcr.io/* ]]; then
  echo "::error::image must be a ghcr.io reference."
  exit 1
fi

ref="${IMAGE#ghcr.io/}"
digest=""
if [[ "${ref}" == *@* ]]; then
  digest="${ref#*@}"
  ref="${ref%%@*}"
  if [[ ! "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    echo "::error::digest must be @sha256: followed by 64 lowercase hex characters."
    exit 1
  fi
fi

tag=""
path="${ref}"
if [[ "${path}" == *:* ]]; then
  tag="${path#*:}"
  path="${path%%:*}"
fi
if [[ "${path}" == *[:@]* ]]; then
  echo "::error::image must contain one tag, one digest, or a tag and a digest."
  exit 1
fi
if [ -z "${tag}" ] && [ -z "${digest}" ]; then
  echo "::error::image needs a tag or a sha256 digest."
  exit 1
fi
if [ -n "${tag}" ] && [[ ! "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  echo "::error::tag '${tag}' is not a valid ImageStream tag."
  exit 1
fi
# OCI name component: alphanumerics, separated by ".", "_", "__", or one or more "-".
if [[ ! "${path}" =~ ^[a-z0-9]+(([.]|_{1,2}|-+)[a-z0-9]+)*(/[a-z0-9]+(([.]|_{1,2}|-+)[a-z0-9]+)*)+$ ]]; then
  echo "::error::image path must be ghcr.io/<owner>/<name> in lowercase."
  exit 1
fi

stream="${path##*/}"
if [ -n "${NAME:-}" ]; then
  stream="${NAME}"
fi
# DNS-1123 subdomain, which allows repeated internal hyphens.
if [[ ! "${stream}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?([.][a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ ]] || [ "${#stream}" -gt 253 ]; then
  echo "::error::ImageStream name '${stream}' must be a DNS-1123 name."
  exit 1
fi
if [ -n "${TAG:-}" ]; then
  tag="${TAG}"
fi
if [ -z "${tag}" ]; then
  tag="${digest#sha256:}"
fi
if [[ ! "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  echo "::error::tag '${tag}' is not a valid ImageStream tag."
  exit 1
fi

if [ -n "${TOKEN:-}" ]; then
  if [[ "${TOKEN}" =~ [[:space:]] ]]; then
    echo "::error::github_token must not contain whitespace."
    exit 1
  fi
  # Repository path, so this token is preferred over a host-wide ghcr.io secret.
  # docker-registry requires a username field; GHCR authenticates the token.
  secret="image-import-$(printf '%s' "${path}:${tag}" | sha256sum | cut -c1-20)"
  trap 'oc delete secret "'"${secret}"'" --ignore-not-found >/dev/null' EXIT
  oc delete secret "${secret}" --ignore-not-found >/dev/null
  oc create secret docker-registry "${secret}" \
    --docker-server="ghcr.io/${path}" \
    --docker-username=USERNAME \
    --docker-password="${TOKEN}" \
    --docker-email=unused
fi

echo "Importing ${stream}:${tag} from ${IMAGE}"
oc import-image "${stream}:${tag}" \
  --from="${IMAGE}" \
  --confirm \
  --import-mode=PreserveOriginal \
  --reference-policy=local

echo "In-cluster pull spec: image-registry.openshift-image-registry.svc:5000/${OC_NAMESPACE}/${stream}:${tag}"
