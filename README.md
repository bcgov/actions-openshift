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
- uses: bcgov/actions-openshift/oc-runner@v0.1.0
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
- uses: bcgov/actions-openshift/crunchy@v0.1.0
```

### 5. [deployer](./deployer) (Composite Action)
Deploy to OpenShift using templates. Verification or penetration tests.
* See [deployer/README.md](./deployer/README.md).

```yaml
- uses: bcgov/actions-openshift/deployer@v0.1.0
```

### 6. Deployer (`.github/workflows/.deployer.yml`)
A reusable workflow that manages Helm and Template-based application deployments to OpenShift. It configures variables, handles release/tag naming conventions, and automates target environment promotions.

#### Example Usage:
```yaml
jobs:
  deploy:
    uses: bcgov/actions-openshift/.github/workflows/.deployer.yml@v1
    secrets: inherit
    with:
      cleanup: helm
      packages: backend frontend migrations
```

### 7. SchemaSpy (`.github/workflows/.schema-spy.yml`)
A reusable workflow that spins up a Postgres/PostGIS service, runs migrations using Flyway, generates interactive database documentation with SchemaSpy, and automatically publishes the results to GitHub Pages.

#### Example Usage:
```yaml
jobs:
  document-db:
    uses: bcgov/actions-openshift/.github/workflows/.schema-spy.yml@v1
    permissions:
      contents: write
    with:
      db_name: app_database
      deploy_dir: docs/schema
```

### 8. PR Close (`.github/workflows/.pr-close.yml`)
A reusable workflow that cleans up OpenShift resources and retags images on pull request close or merge.

#### Example Usage:
```yaml
jobs:
  cleanup:
    uses: bcgov/actions-openshift/.github/workflows/.pr-close.yml@v1
    secrets: inherit
    with:
      cleanup: helm
```

