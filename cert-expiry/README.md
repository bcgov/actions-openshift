# Cert Expiry

On findings, CODEOWNERS get notified: `workflow-notifier` opens an issue. The failing check step is only the mechanism that triggers that notify step.

For each hostname this action runs a read-only `openssl s_client` handshake, reads the public leaf certificate's expiry date, and reports any certificate that expires within `days` (default 30), has expired, or can't be read. It needs no OpenShift credentials, no `oc` login and no `GITHUB_TOKEN`, and changes nothing. It prints only hostnames, expiry dates and days left. Installing a renewed certificate is [`route-tls`](../route-tls/README.md)'s job.

Pin a tag or commit SHA, not `@main`. The runner needs `openssl`, `jq` and `timeout` (all on `ubuntu-*` runners).

## Usage

Each repository schedules its own check. On findings, that job notifies its CODEOWNERS: the action fails the check step (`fail_on_findings`, default `true`) and always sets the `findings` output, then the next step runs [`workflow-notifier`](https://github.com/bcgov/actions/tree/main/workflow-notifier) with `if: failure()`. That opens an issue, or comments on the open one with the same title, assigned to the repository's CODEOWNERS. It reads CODEOWNERS from the workspace, so the job checks out the repository first.

`bcgov/quickstart-openshift` doesn't run this action today. This is a complete standalone workflow (`.github/workflows/cert-expiry.yml`) that would check its prod hosts and notify CODEOWNERS. It can also live as a job in an existing `scheduled.yml`.

- `${{ github.event.repository.name }}-prod.apps.silver.devops.gov.bc.ca`, the prod frontend Route. quickstart's `frontend/openshift.deploy.yml` sets the Route host to `${NAME}-${ZONE}.${DOMAIN}`, quickstart deploys prod with `NAME` = the repository name and `ZONE` = `prod`, and `DOMAIN` defaults to `apps.silver.devops.gov.bc.ca`.
- `${{ vars.ROUTE_HOST }}`, the optional vanity hostname that quickstart's `route-tls.yml` serves. When it isn't set, the line is blank and skipped.

```yaml
# .github/workflows/cert-expiry.yml
name: Cert Expiry

on:
  schedule:
    # Monday 08:17 PT (15:17 UTC)
    - cron: "17 15 * * 1"
  workflow_dispatch:

permissions: {}

jobs:
  cert-expiry:
    name: TLS Certificate Expiry
    runs-on: ubuntu-slim
    timeout-minutes: 10
    permissions:
      contents: read
      issues: write
    steps:
      # workflow-notifier reads CODEOWNERS from the workspace
      - uses: actions/checkout@v7
        with:
          persist-credentials: false

      - name: Check certificate expiry
        uses: bcgov/actions-openshift/cert-expiry@vX.Y.Z
        with:
          hosts: |
            ${{ github.event.repository.name }}-prod.apps.silver.devops.gov.bc.ca
            ${{ vars.ROUTE_HOST }}
          days: "30"

      - name: Notify CODEOWNERS
        if: failure()
        uses: bcgov/actions/workflow-notifier@4026bfd276b8a5839029106099b13edfb594b2c3 # v0.8.0
        with:
          title: "TLS certificate expiring or unreadable"
          labels: ""
          notify_author: "false"
          notify_codeowners: "true"
```

To notify only on certificate findings (not on an input error), give the check step an `id` and use `if: failure() && steps.<id>.outputs.findings != '' && steps.<id>.outputs.findings != '[]'`.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `hosts` | required | Hostnames, one per line (commas or spaces also work). `host` or `host:port`, no scheme; port defaults to 443. Blank lines and `#` comments are skipped. |
| `days` | `30` | Warn when a certificate expires within this many days. Whole number, 1 to 3650. |
| `timeout` | `10` | Seconds to wait for each handshake. Whole number, 1 to 120. |
| `fail_on_findings` | `true` | Fail the step when any host needs attention, so the next step can notify with `if: failure()`. Outputs are written either way. |

Invalid inputs (a URL instead of a hostname, a bad port, `days: 0`, an empty list) fail the step with an `::error::` line and a `Fix:` line.

## Outputs

| Output | Description |
| --- | --- |
| `findings` | JSON array of hosts that need attention, `[]` when all are fine. Each item has `host`, `status` (`expiring`, `expired` or `unreadable`), `not_after` (UTC, empty when unreadable) and `days_left`. |
| `checked` | Number of hosts checked, after removing duplicates. |

The step summary has a table of every host with its status, expiry date and days left.

## Common fixes

| Message | Fix |
| --- | --- |
| `certificate expires ... within 30 days` | Renew the certificate and install it with `route-tls`. |
| `could not read a certificate` | Check the hostname resolves and serves TLS on that port, raise `timeout` for slow hosts, or remove the host if it is retired. |
| `'https://...' is a URL, not a hostname` | List the hostname only, for example `myapp.gov.bc.ca`. |
