# Sysdig Monitor

Create or update Sysdig email alerts for an app on PROD deploy. Designed for BC Gov OpenShift apps following the [quickstart-openshift](https://github.com/bcgov/quickstart-openshift) pattern.

The action is **idempotent** (safe to re-run on every deploy), **non-blocking** (no-op when `SYSDIG_API_TOKEN` is missing), and **additive** (never deletes alerts when template files are removed — clean those up in the Sysdig UI).

## Permissions

To run this action, the calling workflow job must have the following minimum permissions:

```yaml
permissions:
  contents: read  # Required to check out the alert templates this action reads
```

The action talks to the Sysdig API with `sysdig_api_token`; it never uses `GITHUB_TOKEN`.

## How it works

Alert templates live **in your repo**, not in this action. The action scans `monitoring/alerts/*.json` in your repo at run time and upserts each file as a Sysdig alert per component. To add a new alert: drop a JSON file in that directory. To remove the baseline ones: delete them from your repo (then clean up the stale Sysdig alert in the UI).

For each `<basename>.json` × each component, the action upserts an alert named `<app>-<component>-<basename>`. It also upserts one shared email channel `<app>-team-email` with recipients pulled from your `SysdigTeam` CR member list.

## Prerequisites

### 1. SysdigTeam provisioned in your TOOLS namespace

**Do this first.** Until the `SysdigTeam` CR exists and has reconciled, nobody on the team can log into Sysdig at all, and there is no API token to pull — so steps 2 and 3 are blocked on it.

The `SysdigTeam` CRD (`ops.gov.bc.ca/v1alpha1`) is reconciled by the platform's monitoring operator. It creates a Sysdig team scoped to your project set's four namespaces, grants the listed users access to that team, and materializes an API token Secret in the TOOLS namespace.

Commit the manifest as `openshift/sysdig-team.yaml` and apply it to `<licenseplate>-tools` — the CR belongs in the **tools** namespace, not `-prod`:

```yaml
apiVersion: ops.gov.bc.ca/v1alpha1
kind: SysdigTeam
metadata:
  name: <licenseplate>-sysdigteam
  namespace: <licenseplate>-tools
spec:
  team:
    description: The Sysdig Team for the OpenShift Project Set <licenseplate>
    users:
      - name: first.last@gov.bc.ca
        role: ROLE_TEAM_MANAGER
      - name: team-shared-account@gov.bc.ca
        role: ROLE_TEAM_MANAGER
      - name: another.dev@gov.bc.ca
        role: ROLE_TEAM_MANAGER
```

> **`role` must be `ROLE_TEAM_MANAGER` for every user — the other role values do not work.**
> This applies even to members who only need to read dashboards or receive alert email. Don't try to scope people down with a lesser role; use `ROLE_TEAM_MANAGER` for everyone in `spec.team.users[]`.

Note that the live object on cluster will carry a finalizer (`monitoring.devops.gov.bc.ca/finalizer`), `metadata.managedFields`, and a `status` block that the operator writes — none of that belongs in the manifest you commit. Author only `metadata.name`, `metadata.namespace`, and `spec`.

Confirm the operator reconciled before moving on:

```bash
oc -n <licenseplate>-tools get sysdigteam <licenseplate>-sysdigteam -o yaml
```

A healthy CR has `status.monitorTeamID` and `status.secureTeamID` populated and a passing `status.conditions` entry. Team members can then log in to <https://app.sysdigcloud.com> and see the team.

### 2. `SYSDIG_API_TOKEN` set as a GitHub repo secret

Copy it from the in-cluster Secret created in step 1. The token is team-scoped, so it is only as broad as the team the CR provisioned.

### 3. Alert templates committed to your repo

Under `monitoring/alerts/` — see [Alert templates](#alert-templates) below for the schema and a starter file.

Adding/removing alert recipients is done by editing `spec.team.users[]` in the SysdigTeam CR (again, `ROLE_TEAM_MANAGER` on each entry) — the action re-syncs the email channel on every deploy.

## Usage

```yaml
- uses: bcgov/actions/sysdig-monitor@vX.Y.Z # Replace with latest release tag
  with:
    ### Required

    # Sysdig API token, scoped to the project's Sysdig team
    sysdig_api_token: ${{ secrets.SYSDIG_API_TOKEN }}

    # Prod OpenShift namespace
    oc_namespace: abc123-prod

    # Application name (namespaces alert names in the Sysdig UI)
    app: nr-rept


    ### Typical / recommended

    # Path (relative to repo root) to the directory of alert template JSON files.
    # Default: monitoring/alerts
    alerts_dir: monitoring/alerts

    # Comma-separated Deployment names. One alert per file per component.
    # Default: frontend,backend
    components: frontend,backend

    # Minutes a condition must hold before alerting. Acts as the debounce
    # that absorbs rolling-deploy noise.
    # Default: 5
    alert_duration_minutes: "5"


    ### Usually a bad idea / not recommended

    # Sysdig SaaS API base URL. Override only if BC Gov migrates tenancy.
    # Default: https://app.sysdigcloud.com
    sysdig_api_url: https://app.sysdigcloud.com

    # Verbose logging (prints API requests, never bodies)
    # Default: false
    debug: "false"
```

Make sure your workflow runs `actions/checkout` before this action — the alerts directory is read from the consuming repo's checkout.

## Alert templates

Each file in `alerts_dir` is one Sysdig PromQL alert. The filename (without `.json`) becomes the alert-name suffix, so keep names lowercase, dashes/underscores/digits only. The action expects this shape:

```json
{
  "type": "PROMETHEUS",
  "name": "__ALERT_NAME__",
  "description": "Container in __NAMESPACE__/__COMPONENT__ has been in CrashLoopBackOff for over __DURATION_MINUTES__ minutes.",
  "severity": "high",
  "enabled": true,
  "config": {
    "duration": 0,
    "query": "max by (kube_deployment_name, kube_pod_name) (kube_pod_container_status_waiting_reason{reason=\"CrashLoopBackOff\", kube_namespace_name=\"__NAMESPACE__\", kube_deployment_name=\"__APP__-__COMPONENT__-prod\"}) > 0"
  },
  "notificationChannelConfigList": [
    { "type": "EMAIL", "channelId": 0 }
  ]
}
```

The action substitutes the placeholders at apply time:

| Placeholder              | Replaced with                           | Substituted in                    |
|--------------------------|------------------------------------------|------------------------------------|
| `__ALERT_NAME__`         | `<app>-<component>-<filename>`           | `name` (overwritten, value ignored) |
| `__APP__`                | `app` input                              | `description`, `config.query`      |
| `__NAMESPACE__`          | `oc_namespace` input                     | `description`, `config.query`      |
| `__COMPONENT__`          | Current component from `components`      | `description`, `config.query`      |
| `__DURATION_MINUTES__`   | `alert_duration_minutes` input           | `description`                      |

### Matching the right Deployment

`__COMPONENT__` on its own is **not** a Deployment name. Following the quickstart-openshift pattern, `app` is the repo name and Deployments are named `<app>-<component>-<zone>` — so a PROD query must select `kube_deployment_name="__APP__-__COMPONENT__-prod"`. A bare `kube_deployment_name="__COMPONENT__"` matches nothing and the alert silently never fires.

Avoid reaching for a regex (`=~".+-__COMPONENT__-prod"`) instead: it matches every app in the namespace whose Deployment ends the same way, and since PromQL regexes are fully anchored it buys nothing over the exact match. Alerts that aggregate with a bare `max()`/`sum()` across such a match also lose the labels that say *which* Deployment or pod fired — prefer `max by (kube_deployment_name, kube_pod_name) (...)`.

Other fields the action sets unconditionally (any value in your template is overwritten): `config.duration` (computed from `alert_duration_minutes`), `notificationChannelConfigList` (pinned to the upserted email channel).

`severity` is `low | medium | high`. `query` is any PromQL — `kube-state-metrics` series are available out of the box.

## Behaviour

- **Idempotent.** Channels and alerts are upserted by name. Re-running the action on every PROD deploy is the intended pattern.
- **Additive only.** Removing a `*.json` file from your repo does NOT delete the corresponding Sysdig alert — clean those up manually in the Sysdig UI. This is intentional: prevents an accidental file rename from blowing away production alerts.
- **Recipient drift.** The email channel is rewritten with the current SysdigTeam member list every run. To add or remove a recipient, edit the CR and let the next deploy re-sync.
- **Debounce.** Each alert has `config.duration` set from `alert_duration_minutes`, so the brief replica gaps and restarts during a rolling deploy don't self-page.
- **No-op on missing token, no-op on missing alerts dir.** If `sysdig_api_token` is empty/unset or `alerts_dir` doesn't exist or is empty, the action prints a warning and exits 0.

## Architecture notes

- The token is **team-scoped**: the action never needs to know the Sysdig team ID. All API calls implicitly operate within that team.
- The Sysdig team's member list is queried from the API and filtered to exclude auto-injected platform support staff (`admin: true`) — only CR-managed users get email notifications.
- Alerts use Sysdig's PromQL alert type. Metrics rely on the standard `kube-state-metrics` series shipped by the platform.

## Project status

Experimental. Expect tag-by-tag iteration as we shake out edge cases on the first few pilot adoptions.
