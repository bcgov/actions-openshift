# OpenShift Route TLS

Applies an edge-terminated OpenShift Route with your certificate, key, and optional CA bundle. openssl checks that the PEMs match, cover `hostname`, and are not expired. If the Route already has TLS, that material is snapshotted to a Secret before overwrite. The GitHub Action is a thin wrapper around `provision.sh`; run that script locally with files on disk.

The generated Route always uses `termination: edge` and `insecureEdgeTerminationPolicy: Redirect`. A vanity DNS name is one caller. A cluster that requires a custom cert on every Route is the same action.

Leave any platform `*.apps…` Route in place if you still want that hostname.

## Local dry-run (real certs, no GitHub, no cluster)

```bash
cd route-tls
export ROUTE_HOST=app.example.gov.bc.ca
export ROUTE_NAME=myapp-prod-frontend-tls
export TARGET_SERVICE=myapp-prod-frontend
export APP=myapp-prod          # same app= label your PR-close cleanup uses
export TLS_CERTIFICATE_FILE=/path/to/cert.pem
export TLS_PRIVATE_KEY_FILE=/path/to/key.pem
export TLS_CA_CERTIFICATE_FILE=/path/to/ca.pem   # optional
export DRY_RUN=true
./provision.sh
```

That checks the cert matches the key, covers `$ROUTE_HOST`, is not expired, and writes `route.yml` (contains the private key; gitignored; not printed). `oc_*` is not required.

To apply from a laptop you already have `oc` on, unset `DRY_RUN` and set `OC_NAMESPACE`, `OC_SERVER`, and `OC_TOKEN`. Prefer applying from the prod GitHub environment so the apply is audited.

## GitHub Actions

Pin a tag or commit SHA, not `@main`. Callers can keep `permissions: {}`; this action does not checkout and does not use `GITHUB_TOKEN`. On the runner it downloads `oc` itself, then logs in with `oc_server` / `oc_token`. Put the PEMs on the **prod** GitHub environment, not repository secrets, so pull requests cannot read them.

```yaml
- uses: bcgov/actions-openshift/route-tls@v1
  with:
    hostname: app.example.gov.bc.ca
    route_name: myapp-prod-frontend-tls
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

`app` must be the same label cleanup deletes (`name-zone`, e.g. `myapp-prod` or `myapp-123`). If omitted it falls back to `target_service`, which will **not** match NR `oc delete -l app=name-zone` and the Route plus backup Secrets will leak.

## Inputs

| Input | Description | Required | Default |
| --- | --- | --- | --- |
| `hostname` | Route `spec.host` (no `https://`) | Yes | |
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

Local-only env (not GitHub inputs): `TLS_CERTIFICATE_FILE`, `TLS_PRIVATE_KEY_FILE`, `TLS_CA_CERTIFICATE_FILE`, `ROUTE_OUT` (default `route.yml`). The script reads `ROUTE_HOST` (same as `hostname`).

## What it does

1. Fail if the cert and key do not match, the cert is expired, or the cert does not cover `hostname` (CN or SAN, including `*.example.gov.bc.ca`).
2. Unless `dry_run`, snapshot the live Route's TLS into a Secret named `<route>-backup-<sha256-prefix>`, labeled `backup-type=route-tls` and `app=<app>`. Re-applying the same cert is a no-op on that Secret.
3. `oc apply` the generated Route. Private keys are never printed.
