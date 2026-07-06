# actions-openshift
Consolidated repo for bcgov-specific openshift actions. Please feel free to contribute!

## Workflows and Actions

### 1. [Teardown PR Env](./cleanup) (Composite Action)
Cleans up Helm releases, labeled resources, and PVCs in a target OpenShift namespace on pull request close or merge.
* See [cleanup/README.md](./cleanup/README.md) for detailed inputs and usage.

### 2. Deployer (`.github/workflows/.deployer.yml`)
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

### 3. SchemaSpy (`.github/workflows/.schema-spy.yml`)
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
