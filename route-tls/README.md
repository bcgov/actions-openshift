# Route TLS

GitHub Action that applies an OpenShift Route with your TLS certificate, key, and issuing CA. openssl checks that the PEMs match, cover `hostname`, and are not expired. If the Route already has TLS, that material is snapshotted to a Secret before overwrite.

The Route uses `termination: edge` and `insecureEdgeTerminationPolicy: Redirect`. A vanity DNS name is one use; a cluster that requires a custom cert on every Route is the same call.

Pin a tag or commit SHA, not `@main`. Callers can keep `permissions: {}`; this action does not checkout and does not use `GITHUB_TOKEN`.

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
- uses: bcgov/actions-openshift/route-tls@v1
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

First prod run: add `dry_run: "true"` until the job is green, then drop it.

## Inputs

| Input | Description | Required | Default |
| --- | --- | --- | --- |
| `hostname` | Route `spec.host` (no `https://`) | Yes | |
| `target_service` | Service to send traffic to | Yes | |
| `route_name` | OpenShift Route name | No | `<repo>-vanity-url` |
| `tls_certificate` | Leaf (or chain) PEM | Yes | |
| `tls_private_key` | Private key PEM | Yes | |
| `tls_ca_certificate` | Issuing CA PEM | Yes | |
| `oc_namespace` | Namespace | unless `dry_run` | |
| `oc_server` | API URL | unless `dry_run` | |
| `oc_token` | Token | unless `dry_run` | |
| `dry_run` | Validate and write YAML only | No | `false` |

## What it does

1. Fail if the cert and key do not match, the cert is expired, or the cert does not cover `hostname` (CN or SAN, including wildcards).
2. Unless `dry_run`, snapshot the live Route's TLS into a Secret named `<route>-backup-<sha256-prefix>`, labeled `backup-type=route-tls` (no `app` label). Re-applying the same cert is a no-op on that Secret.
3. Download `oc` on the runner if needed, log in, and `oc apply` the Route. Private keys are never printed.

## Local CLI (optional)

`provision.sh` is the same code the Action runs. Use it to dry-run PEMs on disk without GitHub or a cluster.

```bash
cd route-tls
export ROUTE_HOST=app.example.gov.bc.ca
export ROUTE_NAME=myapp-prod-vanity-url
export TARGET_SERVICE=myapp-prod
export TLS_CERTIFICATE_FILE=/path/to/cert.pem
export TLS_PRIVATE_KEY_FILE=/path/to/key.pem
export TLS_CA_CERTIFICATE_FILE=/path/to/ca.pem
export DRY_RUN=true
./provision.sh
```

Writes `route.yml` (contains the private key; gitignored; not printed). To apply from a laptop, unset `DRY_RUN` and set `OC_NAMESPACE`, `OC_SERVER`, and `OC_TOKEN`.
