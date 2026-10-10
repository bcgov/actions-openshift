# Cert Expiry

GitHub Action that warns before TLS certificates expire. For each hostname it runs a read-only `openssl s_client` handshake, reads the public leaf certificate's expiry date, and reports any certificate that expires within `days` (default 30), has expired, or can't be read.

It needs no OpenShift credentials and no `GITHUB_TOKEN`, and changes nothing. It prints only hostnames, expiry dates and days left. Installing a renewed certificate is [`route-tls`](../route-tls/README.md)'s job.

Pin a tag or commit SHA, not `@main`. The runner needs `openssl`, `jq` and `timeout` (all on `ubuntu-*` runners).

## Usage

`bcgov/quickstart-openshift` doesn't run this action today. This is how its weekly `scheduled.yml` would add it for the prod vanity hostname in `vars.ROUTE_HOST` (the host `route-tls` serves), with [`workflow-notifier`](https://github.com/bcgov/actions/tree/main/workflow-notifier) opening or updating an issue for CODEOWNERS when a certificate needs attention:

```yaml
# .github/workflows/scheduled.yml
permissions: {}

jobs:
  # ...stale-branches, ageOutPRs and the other scheduled jobs...

  cert-expiry:
    name: TLS Certificate Expiry
    if: vars.ROUTE_HOST != ''
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    permissions:
      contents: read
      issues: write
    steps:
      - name: Check certificate expiry
        id: check
        uses: bcgov/actions-openshift/cert-expiry@vX.Y.Z
        with:
          hosts: ${{ vars.ROUTE_HOST }}
          days: "30"

      - name: Notify
        if: failure() && steps.check.outputs.findings != '[]'
        uses: bcgov/actions/workflow-notifier@<sha> # <tag>
        with:
          title: "TLS certificate needs attention: ${{ vars.ROUTE_HOST }}"
          labels: ""
          notify_author: "false"
          notify_codeowners: "true"
```

For a list of hosts, commit a file with one hostname per line and pass `hosts_file`. To open one issue per host, run the check with `fail_on_findings: "false"` and feed `findings` to a matrix job, as this repository's own [`cert-expiry.yml`](../.github/workflows/cert-expiry.yml) does.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `hosts` | `""` | Hostnames, one per line (commas or spaces also work). `host` or `host:port`, no scheme; port defaults to 443. `#` starts a comment. |
| `hosts_file` | `""` | File with hostnames in the same format, relative to the workspace (check out the repository first). Combined with `hosts`. |
| `days` | `30` | Warn when a certificate expires within this many days. Whole number, 1 to 3650. |
| `timeout` | `10` | Seconds to wait for each handshake. Whole number, 1 to 120. |
| `fail_on_findings` | `true` | Fail the step when any host needs attention. Outputs are written either way. |

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
