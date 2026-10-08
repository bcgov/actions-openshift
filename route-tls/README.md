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

Upload secrets to the `prod` environment with the GitHub CLI:

```bash
CERT_HOST='myapp.gov.bc.ca' # Replace with the certificate filename prefix
gh secret set TLS_CERTIFICATE --env prod < "${CERT_HOST}.pem"
gh secret set TLS_PRIVATE_KEY --env prod < "${CERT_HOST}.key"
gh secret set TLS_CA_CERTIFICATE --env prod < 'Entrust OV TLS Issuing RSA CA 2.pem'
```

## Standalone Workflow Architecture

**Always deploy as a standalone, on-demand workflow (`.github/workflows/route-tls.yml` with `workflow_dispatch`).**

Do not embed `route-tls` into `merge.yml`, `release.yml`, or continuous deployment pipelines:
- Certificates rotate yearly; application code deploys continuously.
- Decoupling avoids holding or failing application releases for certificate renewals or transient test failures.
- Standalone execution supports `dry_run=true` validation before applying.
- Inlining performs redundant OpenShift API calls, token use, and route reconcile operations on every application release.

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

A finished run records `dry_run=true` or `dry_run=false` on the workflow summary and raises a notice. A real apply names the Route and the live certificate expiry. A failure records `dry_run` and the error. The summary does not include the key.

## What it does

1. Fail if `tls_certificate` holds more than the leaf, the key is encrypted or does not match the cert, the cert or a CA is expired, the CAs are out of order (the first must have issued the leaf, and each later one the CA before it), or the cert does not cover `hostname` (CN or SAN, including wildcards). Each check prints `PASS` or the error. The log shows only names, dates and results, never PEM contents.
2. Log in and read the route. Fail if another route already has `hostname` (OpenShift would create this name and then Reject it). `dry_run=true` stops here. It does not create a Secret and does not apply.
3. Unless `dry_run`, snapshot the live Route's TLS (cert, key, CA) into a Secret named `<route>-backup-<sha256-prefix>`, labeled `backup-type=route-tls` (no `app` label). Re-applying the same cert is a no-op on that Secret. Restore from that Secret if an apply goes wrong. A Route with no inline key has nothing to back up, and the log says so.
4. Unless `dry_run`, `oc apply` the Route (GitHub installs `oc` via `bcgov/action-oc-runner`), then read the live certificate and fail unless its public key matches the certificate that was applied. Private keys are never printed.

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
