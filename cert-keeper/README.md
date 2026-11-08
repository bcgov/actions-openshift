# Cert Keeper

Keeps one hostname's SSL/TLS certificate valid on an OpenShift Route. When the host has no certificate of its own, or is running low, it gets a free [Let's Encrypt](https://letsencrypt.org/) certificate, installs it with [`route-tls`](../route-tls), and cleans up. No Service Desk ticket and no paid certificate per renewal, once the host's DNS already points at the cluster router.

Each repo opts in and runs it for its own hosts. Out of scope: wildcards and DNS-01 (see `bcgov/cert-manager-proxy`), several hosts on one certificate, platforms other than OpenShift Routes, and replacing Entrust where a ministry requires it.

## How it decides

Every run first reads the certificate the host serves today (with [`cert-expiry`](../cert-expiry)) and does nothing unless one of these is true:

| Situation | What it means |
|---|---|
| The served certificate does not cover the host | A new host: with no Route of its own it is served the router's default wildcard certificate |
| The certificate has expired | Renewal was missed |
| A third of its own lifetime or less is left | Time to renew |
| `force: true` | Reissue now, for example after a private key leak |

The "third" comes from each certificate's own lifetime, so one rule fits every length: renewal starts at about 66 days left on a 198 day certificate, 30 on 90, 21 on 64, and 15 to 16 on 45 to 47. Let's Encrypt moves its default to 64 days on 2027-02-10 and 45 days on 2028-02-16 ([schedule](https://letsencrypt.org/2025/12/02/from-90-to-45)), and industry rules cap lifetimes at 47 days from 2029-03-15 ([lifetimes](https://letsencrypt.org/docs/cert-lifetimes/)). At 47 days that is about one renewal a month.

When a certificate is due:

1. Checks that plain HTTP on port 80 answers for the host (any answer, even a redirect or a 503). Without it, validation cannot work, so it fails early with the reason.
2. Logs in through [`oc-runner`](../oc-runner) and creates a throwaway Pod (`lego` plus an idle helper), Service, NetworkPolicy and Route named `cert-keeper-<hash>`, labelled `app.kubernetes.io/managed-by=cert-keeper`.
   - The Route is **plain HTTP** with `path: /.well-known/acme-challenge` on the same host. The router prefers the longer path, so the vanity Route (edge plus `Redirect`) keeps serving everything else.
   - The NetworkPolicy lets the OpenShift router reach the Pod in default-deny namespaces.
   - lego waits 20 s after starting so the router can load the Route before validation.
   - If the host is owned by a Route in another namespace the challenge Route is not admitted and the action fails fast.
3. Waits for lego (`timeout`, default 300 s), copies the PEMs out with `oc exec` (retried through short API drops), and checks the leaf matches the host.
4. Deletes the Pod, Service, NetworkPolicy and Route on success **and** failure. If a runner dies mid-run, sweep with `oc delete route,service,pod,networkpolicy -l app.kubernetes.io/managed-by=cert-keeper`.
5. Installs the certificate with `route-tls`, which creates the Route if it does not exist and keeps its backups of the old certificate.

The ACME account key is ephemeral (one per run). Both containers use `goacme/lego`, pinned by digest.

## Usage

Run it from its own scheduled workflow, daily. The check is cheap and does nothing when the certificate is fine, and a daily schedule tolerates GitHub dropping a run. Never put it in `merge.yml` or deploy pipelines. A complete `.github/workflows/cert-keeper.yml`:

```yaml
name: Cert Keeper

on:
  schedule:
    - cron: "17 15 * * *" # daily, 08:17 PT
  workflow_dispatch:
    inputs:
      force:
        description: Get a new certificate even if the current one is not due
        type: boolean
        default: false

concurrency:
  group: cert-keeper
  cancel-in-progress: false

permissions: {}

jobs:
  cert-keeper:
    name: Keep certificate valid
    environment: prod
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      issues: write
    timeout-minutes: 15
    steps:
      # workflow-notifier reads CODEOWNERS from the workspace
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - uses: bcgov/actions-openshift/cert-keeper@<sha> # vX.Y.Z
        with:
          hostname: ${{ vars.VANITY_HOST }}
          email: ${{ vars.ACME_EMAIL }}
          route_name: ${{ github.event.repository.name }}-vanity-url
          target_service: ${{ github.event.repository.name }}-prod-frontend
          force: ${{ inputs.force || 'false' }}
          oc_namespace: ${{ vars.OC_NAMESPACE }}
          oc_server: ${{ vars.OC_SERVER }}
          oc_token: ${{ secrets.OC_TOKEN }}

      - name: Notify CODEOWNERS
        if: failure()
        uses: bcgov/actions/workflow-notifier@4026bfd276b8a5839029106099b13edfb594b2c3 # v0.8.0
        with:
          title: "Certificate renewal failed"
          labels: ""
          notify_author: "false"
          notify_codeowners: "true"
```

Pin to a release SHA, never `@main`. Also add the host to [`nr-cert-monitor`](https://github.com/bcgov/nr-cert-monitor) if you want a second set of eyes: it checks the certificate itself, so it still alerts if this workflow stops running.

### Before the first run on a new host

- The host's A or CNAME record already points at the cluster router (a one-time Service Desk step).
- Plain HTTP on port 80 reaches the router.
- No Route in another namespace already claims the host.
- Start with `ca: letsencrypt-staging` to prove it end to end; staging certificates are not browser-trusted.

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `hostname` | yes | | One lowercase FQDN, no scheme, port or wildcard |
| `email` | yes | | ACME contact |
| `route_name` | yes | | Route to create or update |
| `target_service` | yes | | Service the Route sends traffic to |
| `ca` | no | `letsencrypt` | `letsencrypt` or `letsencrypt-staging`. An omitted value selects production |
| `force` | no | `false` | Reissue now even if not due |
| `timeout` | no | `300` | Seconds to wait for issuance, at least 30 |
| `oc_namespace`, `oc_server`, `oc_token` | yes | | The token needs create and delete on pods, services, routes and networkpolicies, and `pods/exec` |

## Outputs

| Output | Meaning |
|---|---|
| `due` | `true` when a certificate was needed (and so issued and installed), `false` when the current one was left alone |
| `reason` | Why |
| `not_after` | Expiry of the new certificate; empty when nothing was issued |

## Limits

Let's Encrypt rate limits ([source](https://letsencrypt.org/docs/rate-limits/)):

- **50 new certificates per registered domain per 7 days**, shared by everyone. `bc.ca` is on the Public Suffix List, so the registered domain is `gov.bc.ca` and the whole province shares it. Renewals are exempt from this one.
- **5 certificates per exact set of names per 7 days.** Renewals count, which is why the gate only issues when due, and why repeated `force` runs can lock a host out for days.
- **5 failed validations per host per hour** per account. Debug on `letsencrypt-staging`.

## Common fixes

| Message | Fix |
|---|---|
| `Port 80 on <host> did not answer` | Point the host at the OpenShift router and allow plain HTTP on port 80 |
| `Could not read a certificate for <host> over TLS` | The host does not resolve to the router, or port 443 is blocked |
| `Pod ... cannot start` | The log prints the container state and events; fix the cause they name |
| `challenge Route ... was not admitted` | Another namespace owns the host |
| `lego did not finish within ...s` | DNS for the host must reach this cluster's router; the log prints events |

## Local run

```bash
oc login ... && ACME_HOST=app.example.gov.bc.ca ACME_EMAIL=me@gov.bc.ca CA=letsencrypt-staging ./issue.sh
RENDER_ONLY=true ACME_HOST=... ACME_EMAIL=... ./issue.sh   # print the manifests only
```
