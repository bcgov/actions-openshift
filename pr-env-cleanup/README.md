# PR Environment Cleanup

Scheduled sweep action that removes leftover PR deployments in OpenShift (by `app` label) and/or stale PR databases/users (`app-<pr>`) in a shared Crunchy `PostgresCluster`.

Unlike the inline `ageOutPRs` snippet it replaces, this action:
- Checks live GitHub pull request state (`github.token`) instead of `Deployment.metadata.creationTimestamp`, so closed PRs are swept immediately and active open PRs are not deleted while still receiving pushes.
- Deletes the full [`cleanup-pr`](../cleanup-pr/README.md) resource set (`all,jobs,cronjobs,cm,pvc,secret,networkpolicy,routes,hpa`).
- Anchors deployment matching (`^<prefix>-<pr>(-|$)`) and reads the actual `app` label from each matched Deployment.
- Optionally sweeps `app-<pr>` users/databases from the repo's shared [`crunchy`](../crunchy/README.md) `PostgresCluster`.

## Inputs

| Input | Description | Required | Default |
|---|---|---|---|
| `oc_namespace` | Target OpenShift namespace | **Yes** | N/A |
| `oc_server` | OpenShift API server URL with port | **Yes** | N/A |
| `oc_token` | OpenShift access token | **Yes** | N/A |
| `prefix` | Deployment name prefix to match (`<prefix>-<pr>...`); override when templates use a custom name (e.g. `fom` for `nr-fom`) | No | `${{ github.event.repository.name }}` |
| `cleanup_label` | Clean up labeled OpenShift resources for stale/closed PR deployments | No | `true` |
| `crunchy` | Clean up `app-<pr>` users/databases in the repo's Crunchy `PostgresCluster` | No | `false` |
| `crunchy_release_name` | Crunchy Helm release name override (matches `crunchy` `release_name`) | No | `""` (`pg-<md5>`) |
| `days` | Inactivity threshold in days for open PRs (`updated_at`) | No | `7` |
| `include_open` | Also clean up open PRs inactive for `days` (`false` cleans closed PRs only) | No | `true` |
| `dry_run` | Log matches without deleting OpenShift resources or Crunchy users/databases | No | `false` |
| `repository` | GitHub `owner/repo` used to check PR state | No | `${{ github.repository }}` |
| `token` | GitHub token used to query PR state | No | `${{ github.token }}` |
| `debug` | Enable bash xtrace (`set -x`) | No | `false` |

## Outputs

| Output | Description |
|---|---|
| `deleted_labels` | JSON array of `app` labels deleted (or selected when `dry_run: true`) |
| `deleted_crunchy_prs` | JSON array of PR numbers removed from Crunchy (or selected when `dry_run: true`) |
| `blocked` | `'true'` when OpenShift login failed because the runner IP is blocked |
| `unreachable` | `'true'` when OpenShift login failed because neither the API nor the cluster router answered |

## Usage Example

In `bcgov/quickstart-openshift`'s `.github/workflows/scheduled.yml`, this replaces the inline `ageOutPRs` job (alongside `stale-branches` and feeding `results: needs: [stale-branches, ageOutPRs, ...]`):

```yaml
  ageOutPRs:
    name: PR Deployment Purge
    runs-on: ubuntu-slim
    timeout-minutes: 10
    permissions:
      contents: read
      pull-requests: read
    steps:
      - name: Clean up stale PR deployments
        uses: bcgov/actions-openshift/pr-env-cleanup@vX.Y.Z
        with:
          oc_namespace: ${{ vars.OC_NAMESPACE }}
          oc_server: ${{ vars.OC_SERVER }}
          oc_token: ${{ secrets.oc_token }}
```

### Custom label prefix and Crunchy

For a repository whose OpenShift templates use a custom prefix (for example `nr-fom` uses `fom-<pr>`) or a shared Crunchy cluster:

```yaml
      - name: Clean up stale PR deployments and Crunchy DBs
        uses: bcgov/actions-openshift/pr-env-cleanup@vX.Y.Z
        with:
          prefix: fom
          crunchy: true
          oc_namespace: ${{ vars.OC_NAMESPACE }}
          oc_server: ${{ vars.OC_SERVER }}
          oc_token: ${{ secrets.OC_TOKEN }}
```
