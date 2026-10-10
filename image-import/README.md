# Image Import

Imports one GHCR image into an ImageStream in the target namespace. `importMode: PreserveOriginal` keeps the manifest list. `referencePolicy: Local` makes workloads pull through the integrated registry, which stores a blob the first time it serves that blob.

Import stores the manifest. It does not copy layer blobs. A platform that has not been pulled yet still needs GHCR.

Point the workload at the printed in-cluster pull spec. Deployments that still use `ghcr.io/...` are unchanged by a successful import.

Pin a tag or commit SHA, not `@main`. `oc-runner` checks out the caller repo, so a private repository needs `contents: read` on the job.

## Usage

In quickstart-openshift's `pr-open.yml`, the Builds job (matrix `backend`, `frontend`, `migrations`) runs `bcgov/action-builder-ghcr`. Give that step `id: build` and import what it published. `registry_host` is `ghcr.io` and `image_path` is `/owner/repo/package:tag`, using the first tag, so this imports `backend:<pr>`:

```yaml
- uses: bcgov/action-builder-ghcr@<sha> # vX.Y.Z
  id: build
  with:
    package: ${{ matrix.package }}
    tags: |
      ${{ github.event.number }}
      ${{ github.event.pull_request.head.sha }}
    tag_fallback: latest
    triggers: ('${{ matrix.package }}/', '.github/workflows/pr-open.yml')

- name: Import into OpenShift
  uses: bcgov/actions-openshift/image-import@vX.Y.Z
  with:
    image: ${{ steps.build.outputs.registry_host }}${{ steps.build.outputs.image_path }}
    oc_namespace: ${{ secrets.OC_NAMESPACE }}
    oc_server: ${{ vars.OC_SERVER }}
    oc_token: ${{ secrets.OC_TOKEN }}
```

A digest pin keeps the tag and adds `@sha256:<64 hex>`: `ghcr.io/owner/name:pr-42@sha256:…`. A digest with no tag becomes an ImageStream tag of those 64 hex characters.

`name` and `tag` set the ImageStream destination. They default to the last path segment and the reference tag. A pull request can import one shared image onto its own tag:

```yaml
image: ghcr.io/bcgov/quickstart-openshift/backend:latest
name: image-import
tag: ${{ github.event.number }}
```

OpenShift needs `oc_namespace`, `oc_server`, and `oc_token`. GHCR pulls use a live token, like `bcgov/action-builder-ghcr` and `deployer`: `github_token` defaults to the run's `github.token`. The action stores it in a pull secret scoped to that repository path, as `github.actor`, imports, and deletes the secret. That secret takes precedence over a host-wide `ghcr.io` secret saved in the namespace.

Grant the job `packages: read`. A private package published by another repository must also give the calling repository read access in the package's **Manage Actions access** settings, or pass a PAT as `github_token`. Otherwise GHCR denies the import. The Builds job above already has `packages: write`.

```yaml
permissions:
  contents: read
  packages: read
steps:
  - uses: bcgov/actions-openshift/image-import@vX.Y.Z
    with:
      image: ghcr.io/bcgov/private-app/backend:1.2.3
      oc_namespace: ${{ secrets.OC_NAMESPACE }}
      oc_server: ${{ vars.OC_SERVER }}
      oc_token: ${{ secrets.OC_TOKEN }}
```

Delete those tags when the pull request closes, for example from a `pr-close.yml` step. Deleting the ImageStream removes every pull request's tag.

```yaml
- uses: bcgov/actions-openshift/oc-runner@vX.Y.Z
  env:
    PR: ${{ github.event.number }}
  with:
    oc_namespace: ${{ secrets.OC_NAMESPACE }}
    oc_server: ${{ vars.OC_SERVER }}
    oc_token: ${{ secrets.OC_TOKEN }}
    commands: |
      for package in backend frontend migrations; do
        oc delete imagestreamtag "${package}:${PR}" --ignore-not-found
      done
```

Invalid inputs fail before the import, with an `::error::` line and a `Fix:` line.
