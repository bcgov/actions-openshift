# actions-openshift
Consolidated repo for bcgov-specific openshift actions. Please feel free to contribute!

## Workflows and Actions

*   **[Teardown PR Env](./cleanup)** (Composite Action): Cleans up Helm releases, labeled resources, and PVCs in a target OpenShift namespace on pull request close or merge.
*   **Deployer** (`.github/workflows/.deployer.yml`): Handles Helm and Template-based application deployments to OpenShift.
*   **SchemaSpy** (`.github/workflows/.schema-spy.yml`): Generates database documentation using Flyway and SchemaSpy.
