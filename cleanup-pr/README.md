# PR Cleanup

This composite action cleans up resources in a target OpenShift namespace on pull request close or merge. It handles Helm release uninstalls, label-based resource deletion, and selective PVC removals using the `bcgov/action-oc-runner` action.

## Inputs

| Input | Description | Required | Default |
|---|---|---|---|
| `cleanup` | Type of cleanup to run (`helm` or `label`) | **Yes** | N/A |
| `cleanup_name` | Space-separated list of app labels to delete (if `cleanup` is `label`). Defaults to `repository-target` | No | `""` |
| `repository` | The GitHub repository name | No | `${{ github.event.repository.name }}` |
| `target` | Environment target identifier (e.g. PR number) | No | `${{ github.event.number }}` |
| `remove_pvc` | Comma-separated list of PVCs to delete | No | `""` |
| `oc_server` | OpenShift API server URL | No | `https://api.silver.devops.gov.bc.ca:6443` |
| `oc_namespace` | Target OpenShift namespace | **Yes** | N/A |
| `oc_token` | OpenShift Service Account token | **Yes** | N/A |

## Usage Example

Call this action at the end of your Pull Request pipeline or in a dedicated teardown job:

```yaml
name: PR Teardown

on:
  pull_request:
    types: [closed]

jobs:
  cleanup:
    runs-on: ubuntu-24.04
    steps:
      - name: PR Cleanup
        uses: bcgov/actions-openshift/cleanup-pr@v1
        with:
          cleanup: label
          target: ${{ github.event.number }}
          oc_namespace: ${{ secrets.OC_NAMESPACE }}
          oc_token: ${{ secrets.OC_TOKEN }}
          remove_pvc: data-${{ github.event.repository.name }}-${{ github.event.number }}-bitnami-pg-0
```
