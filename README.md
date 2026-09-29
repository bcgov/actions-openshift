# actions-openshift
Consolidated repo for bcgov-specific openshift actions. Please feel free to contribute!

## Workflows and Actions

### 1. [PR Cleanup](./cleanup-pr) (Composite Action)
Cleans up Helm releases, labeled resources, and PVCs in a target OpenShift namespace on pull request close or merge.
* See [cleanup-pr/README.md](./cleanup-pr/README.md) for detailed inputs and usage.

### 2. [Route TLS](./route-tls) (Composite Action)
GitHub Action that applies an OpenShift Route with a custom TLS certificate (openssl checks and archival backups).
* See [route-tls/README.md](./route-tls/README.md) for secrets, inputs, and usage.


### 3. [oc-runner](./oc-runner) (Composite Action)
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


### 4. [crunchy](./crunchy) (Composite Action)
Deploy Crunchy Postgres on OpenShift (PR pipelines and cleanup).
* See [crunchy/README.md](./crunchy/README.md).

```yaml
- uses: bcgov/actions-openshift/crunchy@vX.Y.Z
```

### 5. [deployer](./deployer) (Composite Action)
Deploy to OpenShift using templates. Verification or penetration tests.
* See [deployer/README.md](./deployer/README.md).

```yaml
- uses: bcgov/actions-openshift/deployer@vX.Y.Z
```

### 6. SchemaSpy (`.github/workflows/.schema-spy.yml`)
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

## Operational Scripts

Standalone CLI utilities that a person runs with their own login (certificate management, deployment renames, Postgres transfers and comparisons, rights reports) now live in [bcgov/devops-scripts](https://github.com/bcgov/devops-scripts):

* Certificate management: [`cert/`](https://github.com/bcgov/devops-scripts/tree/main/cert)
* OpenShift & database operations, including the Postgres migration walkthrough: [`oc/`](https://github.com/bcgov/devops-scripts/tree/main/oc)



