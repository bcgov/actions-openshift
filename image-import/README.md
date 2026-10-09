# Image Import

Imports one GHCR image into an ImageStream in the target namespace. The ImageStream tag uses `referencePolicy: Local` and `importMode: PreserveOriginal`, so a Deployment that points at the internal registry keeps the manifest list and can pull after GHCR is unreachable.

The cluster pulls GHCR at import time. This action does not copy blobs through the GitHub runner.

Point the workload at the printed in-cluster pull spec. Deployments that still use `ghcr.io/...` are unchanged by a successful import.

Pin a tag or commit SHA, not `@main`. `oc-runner` checks out the caller repo, so a private repository needs `contents: read` on the job.

## Usage

`builder` publishes `registry_host` (`ghcr.io`) and `image_path` (`/owner/repo/image:tag`). Join them:

```yaml
- name: Import into OpenShift
  uses: bcgov/actions-openshift/image-import@vX.Y.Z
  with:
    image: ${{ steps.build.outputs.registry_host }}${{ steps.build.outputs.image_path }}
    oc_namespace: ${{ vars.OC_NAMESPACE }}
    oc_server: ${{ vars.OC_SERVER }}
    oc_token: ${{ secrets.OC_TOKEN }}
```

A digest pin keeps the tag and adds `@sha256:<64 hex>`: `ghcr.io/owner/name:pr-42@sha256:…`. A digest with no tag becomes an ImageStream tag of those 64 hex characters.

The ImageStream name is the last path segment. That segment must be a DNS-1123 name.
