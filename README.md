# actions-openshift
Consolidated repo for bcgov-specific openshift actions. Please feel free to contribute!

## Workflows and Actions

### 1. [PR Cleanup](./cleanup-pr) (Composite Action)
Cleans up Helm releases, labeled resources, and PVCs in a target OpenShift namespace on pull request close or merge.
* See [cleanup-pr/README.md](./cleanup-pr/README.md) for detailed inputs and usage.

### 2. [Route TLS](./route-tls) (Composite Action)
GitHub Action that applies an OpenShift Route with a custom TLS certificate (openssl checks and archival backups).
* See [route-tls/README.md](./route-tls/README.md) for secrets, inputs, and usage.


### 3. [Image Import](./image-import) (Composite Action)
Imports one GHCR image into a namespace ImageStream (`referencePolicy: Local`, `importMode: PreserveOriginal`).
* See [image-import/README.md](./image-import/README.md) for the reference format and pull spec.

```yaml
- uses: bcgov/actions-openshift/image-import@vX.Y.Z
  with:
    image: ${{ steps.build.outputs.registry_host }}${{ steps.build.outputs.image_path }}
    oc_namespace: ${{ vars.OC_NAMESPACE }}
    oc_server: ${{ vars.OC_SERVER }}
    oc_token: ${{ secrets.OC_TOKEN }}
```

### 4. [oc-runner](./oc-runner) (Composite Action)
Login and run `oc` commands (and optional cronjobs) on OpenShift.
* See [oc-runner/README.md](./oc-runner/README.md) for inputs and usage.

```yaml
- uses: bcgov/actions-openshift/oc-runner@vX.Y.Z
  with:
    oc_namespace: ${{ vars.oc_namespace }}
    oc_server: ${{ vars.oc_server }}
    oc_token: ${{ secrets.OC_TOKEN }}
    commands: oc whoami
```


### 5. [crunchy](./crunchy) (Composite Action)
Deploy Crunchy Postgres on OpenShift (PR pipelines and cleanup).
* See [crunchy/README.md](./crunchy/README.md).

```yaml
- uses: bcgov/actions-openshift/crunchy@vX.Y.Z
```

### 6. [deployer](./deployer) (Composite Action)
Deploy to OpenShift using templates. Verification or penetration tests.
* See [deployer/README.md](./deployer/README.md).

```yaml
- uses: bcgov/actions-openshift/deployer@vX.Y.Z
```

### 7. SchemaSpy (`.github/workflows/.schema-spy.yml`)
A reusable workflow that spins up a Postgres/PostGIS service, runs migrations using Flyway, generates interactive database documentation with SchemaSpy, and automatically publishes the results to GitHub Pages.

#### Example Usage:
```yaml
jobs:
  document-db:
    uses: bcgov/actions-openshift/.github/workflows/.schema-spy.yml@vX.Y.Z
    permissions:
      contents: write
    with:
      db_name: app_database
      deploy_dir: docs/schema
```

### 8. Runner reachability records (`.github/workflows/probe-runner-*.yml`)
Internal records of whether GitHub-hosted runner IPs can reach the OpenShift APIs (background: #49). Nothing alerts on blocked runners; the runs stay green.
* `probe-runner-reachability.yml` runs every 6 hours, probes the gold and silver APIs (:6443) and the silver router (:443) from 20 runners, writes a table to the run summary and uploads a `probe-results` JSON artifact (kept 14 days). A blocked runner is a warning; the run fails only when samples are missing, and then skips the upload so an earlier, complete record is kept.
* `probe-runner-report.yml` runs weekly and summarizes the past 14 days of `probe-results`: this week vs last week, block rate per /24 runner IP range (always, sometimes or never blocked), and the gold vs silver split.

## Operational Scripts

Standalone CLI utilities that a person runs with their own login (certificate management, deployment renames, Postgres transfers and comparisons, rights reports) now live in [bcgov/devops-scripts](https://github.com/bcgov/devops-scripts):

* Certificate management: [`cert/`](https://github.com/bcgov/devops-scripts/tree/main/cert)
* OpenShift & database operations, including the Postgres migration walkthrough: [`oc/`](https://github.com/bcgov/devops-scripts/tree/main/oc)



