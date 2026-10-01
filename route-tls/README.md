# Route TLS

GitHub Action that applies an OpenShift Route with your TLS certificate, key, and issuing CA. openssl checks that the PEMs match, cover `hostname`, and are not expired. If the Route already has TLS, that material is snapshotted to a Secret before overwrite.

The Route uses `termination: edge` and `insecureEdgeTerminationPolicy: Redirect`.

Pin a tag or commit SHA, not `@main`. This action does not use `GITHUB_TOKEN` itself. Non-dry-run jobs use `bcgov/action-oc-runner`, which checkouts the caller repo (that step needs `contents: read` if the repository is private).

## GitHub secrets

Put the PEMs on a **prod** GitHub Environment (not repository secrets), so pull-request jobs cannot read them. The job that calls this action must use that environment. OpenShift login uses environment secrets `OC_NAMESPACE` and `OC_TOKEN`, and variable `OC_SERVER`.

NR cert packages from Entrust look like `app.example.gov.bc.ca/`. Map them like this:

| Secret | File in the package | Notes |
| --- | --- | --- |
| `TLS_CERTIFICATE` | `<host>.pem` | The leaf only (CN/SAN is `hostname`). |
| `TLS_PRIVATE_KEY` | `<host>.key` | Unencrypted PKCS#8 (`BEGIN PRIVATE KEY`). Never commit this. |
| `TLS_CA_CERTIFICATE` | `Entrust OV TLS Issuing RSA CA 2.pem` | The issuing CA only. One PEM. |

Leave out **Sectigo Public Server Authentication Root R46.pem** and **USERTrust RSA Certification Authority.pem**. Those are roots; clients already have them. Leave out `<host>.csr`; the request is finished.

## Usage

```yaml
- uses: bcgov/actions-openshift/route-tls@vX.Y.Z
  with:
    hostname: app.example.gov.bc.ca
    target_service: myapp-prod
    tls_certificate: ${{ secrets.TLS_CERTIFICATE }}
    tls_private_key: ${{ secrets.TLS_PRIVATE_KEY }}
    tls_ca_certificate: ${{ secrets.TLS_CA_CERTIFICATE }}
    oc_namespace: ${{ secrets.OC_NAMESPACE }}
    oc_server: ${{ vars.OC_SERVER }}
    oc_token: ${{ secrets.OC_TOKEN }}
```

`route_name` defaults to `<repository>-vanity-url` (e.g. `myapp-vanity-url`) so PR-close `app=` sweeps do not delete it. Override `route_name` if you already have a name.

The action `dry_run` input defaults to `false`. For a manual **Run workflow** form, keep `dry_run` as a choice that defaults to `true`. GitHub shows one `description` string for that input; the dropdown options are still `true` and `false`. Copy this workflow into the app repo (hostname, route, and service are per app). `run-name` and the extra `description` input are workflow UI. They are not action inputs.

```yaml
name: Route TLS
run-name: "Route TLS dry_run=${{ inputs.dry_run }} — ${{ inputs.description }}"

on:
  workflow_dispatch:
    inputs:
      dry_run:
        description: "Dry run. True = validate only, false = apply."
        required: true
        type: choice
        default: "true"
        options:
          - "true"
          - "false"
      description:
        description: "Shown on this workflow run."
        required: true
        type: string

permissions: {}

jobs:
  route-tls:
    name: Route TLS (dry_run=${{ inputs.dry_run }})
    environment: prod
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    timeout-minutes: 5
    steps:
      - uses: bcgov/actions-openshift/route-tls@vX.Y.Z
        with:
          hostname: app.example.gov.bc.ca
          route_name: myapp-prod-vanity-url
          target_service: myapp-prod
          tls_certificate: ${{ secrets.TLS_CERTIFICATE }}
          tls_private_key: ${{ secrets.TLS_PRIVATE_KEY }}
          tls_ca_certificate: ${{ secrets.TLS_CA_CERTIFICATE }}
          oc_namespace: ${{ secrets.OC_NAMESPACE }}
          oc_server: ${{ vars.OC_SERVER }}
          oc_token: ${{ secrets.OC_TOKEN }}
          dry_run: ${{ inputs.dry_run }}
```

## Inputs

| Input | Description | Required | Default |
| --- | --- | --- | --- |
| `hostname` | Route `spec.host` (no `https://`) | Yes | |
| `target_service` | Service to send traffic to | Yes | |
| `route_name` | OpenShift Route name | No | `<repo>-vanity-url` |
| `tls_certificate` | Leaf PEM | Yes | |
| `tls_private_key` | Private key PEM | Yes | |
| `tls_ca_certificate` | Issuing CA PEM | Yes | |
| `oc_namespace` | Namespace | Yes | |
| `oc_server` | API URL | Yes | |
| `oc_token` | Token | Yes | |
| `dry_run` | Log in and read the route. Do not create the backup Secret or apply | No | `false` |

A finished run records `dry_run=true` or `dry_run=false` on the workflow summary and raises a notice. A failure records `dry_run` and the error. The summary does not include the key.

## What it does

1. Fail if the cert and key do not match, the issuing CA did not sign the leaf, the cert is expired, or the cert does not cover `hostname` (CN or SAN, including wildcards).
2. Log in and read the route. `dry_run=true` stops here. It does not create a Secret and does not apply.
3. Unless `dry_run`, snapshot the live Route's TLS (cert, key, CA) into a Secret named `<route>-backup-<sha256-prefix>`, labeled `backup-type=route-tls` (no `app` label). Re-applying the same cert is a no-op on that Secret. Restore from that Secret if an apply goes wrong.
4. Unless `dry_run`, `oc apply` the Route (GitHub installs `oc` via `bcgov/action-oc-runner`). Private keys are never printed.

## Local CLI (optional)

`provision.sh` is the same code the Action runs. A dry run still logs in and reads the route. It needs `oc` and the three `OC_*` values.

```bash
cd route-tls
export ROUTE_HOST=app.example.gov.bc.ca
export ROUTE_NAME=myapp-prod-vanity-url
export TARGET_SERVICE=myapp-prod
export TLS_CERTIFICATE_FILE=/path/to/cert.pem
export TLS_PRIVATE_KEY_FILE=/path/to/key.pem
export TLS_CA_CERTIFICATE_FILE=/path/to/ca.pem
export OC_NAMESPACE=abc123-prod
export OC_SERVER=https://api.silver.devops.gov.bc.ca:6443
export OC_TOKEN
export DRY_RUN=true
./provision.sh
```

Writes `route.yml` (contains the private key; gitignored; not printed). To apply from a laptop, unset `DRY_RUN`.
