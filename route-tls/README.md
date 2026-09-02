# Route TLS

GitHub Action that applies an OpenShift Route with your TLS certificate, key, and optional CA bundle. openssl checks that the PEMs match, cover `hostname`, and are not expired. If the Route already has TLS, that material is snapshotted to a Secret before overwrite.

The Route uses `termination: edge` and `insecureEdgeTerminationPolicy: Redirect`. A vanity DNS name is one use; a cluster that requires a custom cert on every Route is the same call.

Pin a tag or commit SHA, not `@main`. Callers can keep `permissions: {}`; this action does not checkout and does not use `GITHUB_TOKEN`.

## GitHub secrets

Put the PEMs on a **prod** GitHub Environment (not repository secrets), so pull-request jobs cannot read them. Typical names:

| Secret | What to paste |
| --- | --- |
| `TLS_CERTIFICATE` | Leaf certificate PEM (or leaf + chain) |
| `TLS_PRIVATE_KEY` | Private key PEM |
| `TLS_CA_CERTIFICATE` | Intermediate CA bundle PEM (optional; omit the public root) |

The job that calls this action must use `environment: prod` (or whichever environment holds those secrets). You still pass OpenShift login as today: `oc_namespace` and `oc_token` from that environment, `oc_server` from variables.

## Usage

```yaml
- uses: bcgov/actions-openshift/route-tls@v1
  with:
    hostname: app.example.gov.bc.ca
    route_name: myapp-prod-tls
    target_service: myapp-prod
    app: myapp-prod
    tls_certificate: ${{ secrets.TLS_CERTIFICATE }}
    tls_private_key: ${{ secrets.TLS_PRIVATE_KEY }}
    tls_ca_certificate: ${{ secrets.TLS_CA_CERTIFICATE }}
    oc_namespace: ${{ secrets.oc_namespace }}
    oc_server: ${{ vars.oc_server }}
    oc_token: ${{ secrets.oc_token }}
```

First prod run: add `dry_run: "true"` until the job is green, then drop it.

`app` must be the same label cleanup deletes (`name-zone`, e.g. `myapp-prod`). If omitted it falls back to `target_service`, which may not match `oc delete -l app=name-zone`.

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

## What it does

1. Fail if the cert and key do not match, the cert is expired, or the cert does not cover `hostname` (CN or SAN, including wildcards).
2. Unless `dry_run`, snapshot the live Route's TLS into a Secret named `<route>-backup-<sha256-prefix>`, labeled `backup-type=route-tls` and `app=<app>`. Re-applying the same cert is a no-op on that Secret.
3. Download `oc` on the runner if needed, log in, and `oc apply` the Route. Private keys are never printed.

## Local CLI (optional)

`provision.sh` is the same code the Action runs. Use it to dry-run PEMs on disk without GitHub or a cluster.

```bash
cd route-tls
export ROUTE_HOST=app.example.gov.bc.ca
export ROUTE_NAME=myapp-prod-tls
export TARGET_SERVICE=myapp-prod
export APP=myapp-prod
export TLS_CERTIFICATE_FILE=/path/to/cert.pem
export TLS_PRIVATE_KEY_FILE=/path/to/key.pem
export TLS_CA_CERTIFICATE_FILE=/path/to/ca.pem
export DRY_RUN=true
./provision.sh
```

Writes `route.yml` (contains the private key; gitignored; not printed). To apply from a laptop, unset `DRY_RUN` and set `OC_NAMESPACE`, `OC_SERVER`, and `OC_TOKEN`.
