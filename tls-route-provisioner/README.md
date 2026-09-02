# OpenShift TLS Vanity Route Provisioner

Provisions an edge-terminated vanity Route with openssl cert/key/host checks and an archival backup of whatever TLS is already on that Route. The GitHub Action is a thin wrapper around `provision.sh`; run that script locally with real PEMs.

The generated Route always uses `termination: edge` and `insecureEdgeTerminationPolicy: Redirect`. Keep the platform `*.apps.gold.devops.gov.bc.ca` Route in place as a second Route to the same Service.

## Local dry-run (real certs, no GitHub, no cluster)

```bash
cd tls-route-provisioner
export VANITY_URL=fam.example.gov.bc.ca
export ROUTE_NAME=nr-fam-prod-frontend-vanity
export TARGET_SERVICE=nr-fam-prod-frontend
export APP=nr-fam-prod          # same app= label your PR-close cleanup uses
export TLS_CERTIFICATE_FILE=/path/to/cert.pem
export TLS_PRIVATE_KEY_FILE=/path/to/key.pem
export TLS_CA_CERTIFICATE_FILE=/path/to/ca.pem   # optional
export DRY_RUN=true
./provision.sh
```

That checks the cert matches the key, covers `$VANITY_URL`, is not expired, and writes `route.yml` (contains the private key; gitignored; not printed). `oc_*` is not required.

To apply from a laptop you already have `oc` on, unset `DRY_RUN` and set `OC_NAMESPACE`, `OC_SERVER`, and `OC_TOKEN`. Prefer applying from the prod GitHub environment so the apply is audited.

## GitHub Actions

Pin a tag or commit SHA, not `@main`. Callers can keep `permissions: {}`; this action does not checkout and does not use `GITHUB_TOKEN`. On the runner it downloads `oc` itself, then logs in with `oc_server` / `oc_token`. Put the PEMs on the **prod** GitHub environment, not repository secrets, so pull requests cannot read them.

```yaml
- uses: bcgov/actions-openshift/tls-route-provisioner@v1
  with:
    vanity_url: fam.example.gov.bc.ca
    route_name: myapp-prod-frontend-vanity
    target_service: myapp-prod-frontend
    app: myapp-prod
    tls_certificate: ${{ secrets.TLS_CERTIFICATE }}
    tls_private_key: ${{ secrets.TLS_PRIVATE_KEY }}
    tls_ca_certificate: ${{ secrets.TLS_CA_CERTIFICATE }}
    oc_namespace: ${{ secrets.oc_namespace }}
    oc_server: ${{ vars.oc_server }}
    oc_token: ${{ secrets.oc_token }}
```

First prod run: add `dry_run: "true"` until the job is green, then drop it.

`app` must be the same label cleanup deletes (`name-zone`, e.g. `nr-fam-prod` or `nr-fam-123`). If omitted it falls back to `target_service`, which will **not** match NR `oc delete -l app=name-zone` and the vanity Route plus backup Secrets will leak.

## Inputs

| Input | Description | Required | Default |
| --- | --- | --- | --- |
| `vanity_url` | Route host (no `https://`) | Yes | |
| `route_name` | OpenShift Route name | Yes | |
| `target_service` | Service to send traffic to | Yes | |
| `app` | `app=` label for the Route and backup Secrets | No | `target_service` |
| `tls_certificate` | Leaf (or chain) PEM | Yes | |
| `tls_private_key` | Private key PEM | Yes | |
| `tls_ca_certificate` | CA bundle PEM | No | `""` |
| `oc_namespace` | Namespace | unless `dry_run` | |
| `oc_server` | API URL | unless `dry_run` | |
| `oc_token` | Token | unless `dry_run` | |
| `dry_run` | Validate and write YAML only | No | `false` |
| `insecure_skip_tls_verify` | Skip API TLS verify | No | `true` |

Local-only env (not GitHub inputs): `TLS_CERTIFICATE_FILE`, `TLS_PRIVATE_KEY_FILE`, `TLS_CA_CERTIFICATE_FILE`, `ROUTE_OUT` (default `route.yml`).

## What it does

1. Fail if the cert and key do not match, the cert is expired, or the cert does not cover `vanity_url` (CN or SAN, including `*.example.gov.bc.ca`).
2. Unless `dry_run`, snapshot the live Route's TLS into a Secret named `<route>-backup-<sha256-prefix>`, labeled `backup-type=vanity-tls` and `app=<app>`. Re-applying the same cert is a no-op on that Secret.
3. `oc apply` the generated Route. Private keys are never printed.
