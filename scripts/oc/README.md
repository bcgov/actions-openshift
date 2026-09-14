# OpenShift & Database Utilities

Standalone CLI scripts for OpenShift operations and PostgreSQL database management.

## Scripts

### 1. `rename_deployment.sh`
Renames an OpenShift deployment by exporting its manifest, updating metadata and label selectors (`app=...`), deleting the old deployment, and applying the new one.

```bash
# Rename to <source>-prev by default:
./scripts/oc/rename_deployment.sh my-app-frontend

# Rename to explicit target:
./scripts/oc/rename_deployment.sh my-app-frontend my-app-frontend-v2
```

### 2. `db_transfer.sh`
Streams a binary `pg_dump` from one container/pod directly to `pg_restore` in another container/pod without writing intermediate dump files to disk. Automatically filters conflicting PostGIS extension objects and applies `--no-owner --no-privileges`.

```bash
./scripts/oc/db_transfer.sh <source-deployment> <target-deployment>

# Example:
./scripts/oc/db_transfer.sh my-app-db-prev my-app-db
```

### 3. `db_compare.sh`
Compares PostgreSQL table row counts between two database deployments to verify data migration integrity.

```bash
./scripts/oc/db_compare.sh <source-deployment> <target-deployment>

# Example:
./scripts/oc/db_compare.sh my-app-db-prev my-app-db
```

### 4. `rights_reporter.sh`
Audits and reports OpenShift user roles and RBAC bindings across all projects accessible to the active `oc` session (`oc whoami`). Analyzes role distribution and flags potential security/governance risks (e.g. projects with excess admins or missing view/edit roles).

```bash
# Default roles (admin, edit, view):
./scripts/oc/rights_reporter.sh

# Specific roles:
./scripts/oc/rights_reporter.sh "admin edit view basic-user"

# Remote execution:
curl -fsSL https://raw.githubusercontent.com/bcgov/actions-openshift/main/scripts/oc/rights_reporter.sh | bash
```

### Prerequisites
- Active OpenShift CLI session (`oc whoami`)
- `jq` installed locally
- `bc` installed locally (for `rights_reporter.sh` ratio calculations)
