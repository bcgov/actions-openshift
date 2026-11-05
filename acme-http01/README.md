# ACME HTTP-01

Issues a certificate for **one hostname** with ACME HTTP-01 (Let's Encrypt **staging** by default) and outputs PEMs shaped for [`route-tls`](../route-tls). No DNS TXT records and no Service Desk ticket per renewal once the host's A/CNAME already points at the cluster router.

Out of scope: wildcards and DNS-01 (see `bcgov/cert-manager-proxy`), multiple hosts per cert, org-wide self-serve, replacing Entrust where a ministry requires it.

## How it works

1. Logs in through [`oc-runner`](../oc-runner).
2. Creates a throwaway Pod (`lego` + an idle helper), Service and Route named `acme-http01-<hash>` in `oc_namespace`, labelled `app.kubernetes.io/managed-by=acme-http01`.
   - The Route is **plain HTTP** with `path: /.well-known/acme-challenge/` on the same host. The router prefers the longer path, so the vanity Route (edge + `Redirect`) keeps serving everything else; the challenge path is not redirected to HTTPS.
   - If the host is owned by a Route in another namespace the challenge Route is not admitted and the action fails fast.
3. Waits for lego (`timeout`, default 300 s), copies the PEMs out with `oc exec`, checks the leaf matches `hostname`.
4. Deletes the Pod, Service and Route on success **and** failure (`trap EXIT`). The Pod also has `activeDeadlineSeconds`, so a cancelled job does not leave it running; if a runner dies mid-run, sweep with `oc delete route,service,pod -l app.kubernetes.io/managed-by=acme-http01`.

The ACME account key is ephemeral (one per run). Images: `goacme/lego` pinned by digest; helper `ubi9/ubi-minimal`.

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `hostname` | yes | | One lowercase FQDN, no scheme/port/wildcard |
| `email` | yes | | ACME contact |
| `acme_server` | no | `staging` | `staging` or `production` |
| `key_type` | no | `rsa2048` | `ec256`, `ec384`, `rsa2048`, `rsa3072`, `rsa4096` |
| `timeout` | no | `300` | Seconds, >= 30 |
| `oc_namespace`, `oc_server`, `oc_token` | yes | | Token needs create/delete on pods, services, routes and `pods/exec` |

## Outputs

| Output | Maps to `route-tls` |
|---|---|
| `tls_certificate` | `tls_certificate` (leaf only) |
| `tls_ca_certificate` | `tls_ca_certificate` (issuer chain, no root) |
| `tls_private_key` | `tls_private_key` |
| `not_after` | leaf expiry |

PEM outputs are masked. Files are also written to `$RUNNER_TEMP/acme-http01/` (`tls.crt`, `ca.pem`, `fullchain.pem`, `tls.key`, mode 600).

## Staging first, then production

1. Run with `acme_server: staging` and `route-tls` `dry_run: true`. Staging certs are **not browser-trusted** (`(STAGING)` issuer) but prove DNS, router admission and the challenge path.
2. Switch to `acme_server: production` only after staging succeeds.

**Production rate limits** (Let's Encrypt, see <https://letsencrypt.org/docs/rate-limits/>): 5 certificates per exact host set per 7 days, 50 per registered domain (`gov.bc.ca` is shared across the whole province) per 7 days, 5 failed validations per host per hour. Do not loop production runs, do not run on every deploy, and debug on staging. Renew on a monthly-ish schedule (certs last 90 days or less); `cert-expiry` / `bcgov/nr-cert-monitor` alerts if renewals stop.

## Usage (standalone workflow)

Like `route-tls`, keep this in its own on-demand / scheduled workflow, never inside `merge.yml` or deploy pipelines. Example `.github/workflows/acme-tls.yml` in a quickstart-shaped repo:

```yaml
name: ACME TLS

on:
  schedule:
    - cron: "0 15 1 * *" # monthly, 15:00 UTC on the 1st
  workflow_dispatch:
    inputs:
      acme_server:
        type: choice
        options: [staging, production]
        default: staging
      dry_run:
        description: route-tls dry run
        type: choice
        options: ["true", "false"]
        default: "true"

concurrency:
  group: acme-tls
  cancel-in-progress: false

permissions: {}

jobs:
  renew:
    name: Issue and apply
    environment: prod
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - id: acme
        uses: bcgov/actions-openshift/acme-http01@<sha> # vX.Y.Z
        with:
          hostname: ${{ vars.VANITY_HOST }}
          email: ${{ vars.ACME_EMAIL }}
          acme_server: ${{ inputs.acme_server || 'production' }}
          oc_namespace: ${{ vars.OC_NAMESPACE }}
          oc_server: ${{ vars.OC_SERVER }}
          oc_token: ${{ secrets.OC_TOKEN }}

      - uses: bcgov/actions-openshift/route-tls@<sha> # vX.Y.Z
        with:
          hostname: ${{ vars.VANITY_HOST }}
          route_name: ${{ github.event.repository.name }}-vanity-url
          target_service: ${{ github.event.repository.name }}-prod-frontend
          tls_certificate: ${{ steps.acme.outputs.tls_certificate }}
          tls_private_key: ${{ steps.acme.outputs.tls_private_key }}
          tls_ca_certificate: ${{ steps.acme.outputs.tls_ca_certificate }}
          dry_run: ${{ inputs.dry_run || 'false' }}
          oc_namespace: ${{ vars.OC_NAMESPACE }}
          oc_server: ${{ vars.OC_SERVER }}
          oc_token: ${{ secrets.OC_TOKEN }}
```

Scheduled runs use production; start with `workflow_dispatch` on staging and enable the schedule once a production run has succeeded. Pin both actions to a release SHA, never `@main`.

## Local run

```bash
oc login ... && ACME_HOST=app.example.gov.bc.ca ACME_EMAIL=me@gov.bc.ca ./issue.sh
RENDER_ONLY=true ACME_HOST=... ACME_EMAIL=... ./issue.sh   # print the manifests only
```
