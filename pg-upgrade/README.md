# pg-upgrade

> **Experimental.** Inputs and behaviour may change until [bcgov/nr-old-growth](https://github.com/bcgov/nr-old-growth) has completed a PROD upgrade with this action. Follow the [adoption pattern](#adoption-pattern): rehearse on TEST data before TEST and PROD upgrade.

Moves a PostgreSQL or PostGIS database to a newer major version during a deploy. The new major runs as a separate, empty database next to the old one. This action copies the data across, checks every table's row count, and pauses writes on the old database so no rows are lost in the switch. Nothing changes for repos that don't call it.

It runs whenever a workflow calls it and the old database's Service still exists, whoever bumped the image tag. Once an upgrade has finished, later runs report `already-upgraded` and do nothing.

## How it works

1. **Checks before anything changes.** Both databases accept connections; the image's major matches the target and is newer than the source; the target is empty (no tables, views, sequences or functions outside extensions); every extension the source uses (such as `postgis`) is available on the target. A ConfigMap `<target>-pg-upgrade` records the upgrade and stops a second upgrade or a rollback from starting at the same time. If the runner loses track of a running Job, the record stays until someone checks that Job.
2. **Write pause.** The action sets `default_transaction_read_only = on` on the source database and ends that database's open sessions. Clients reconnect read-only: reads keep working and writes fail until the app is switched to the new database. This covers every writer (backend pods, CronJobs, other apps) without scaling anything down. The source stays read-only afterwards as the rollback copy. Sessions the source user can't end (other roles) fail the step before anything is copied.
3. **Copy and verify in one transaction.** `pg_dump` (custom format, from the new major's client) reads the source at a single snapshot; the same snapshot gives the exact row count of every table (`count(*)`, not estimates) and each sequence's value. The restore and the checks run inside one transaction on the target, with `ON_ERROR_STOP`. Any error, a table missing or extra, or a row count or sequence that differs ends the transaction without `COMMIT`, so the target stays empty and the write pause is lifted.
4. **No writes during the copy.** A client can still turn the read-only default off for its own session. So before `COMMIT`, the action checks the source's table statistics: if any row was inserted, updated or deleted since the pause, or a write transaction is still open, nothing is committed. This waits about 10 seconds before and after the copy, because PostgreSQL reports finished writes to its statistics with that delay. Open write transactions of other roles are only visible when the source user is a superuser.
5. **Result.** On success the ConfigMap says `done`, the step outputs `upgraded`, and the target gets `ANALYZE` so its planner has statistics. On failure the step fails with an `::error::` line and a `Fix:` line. If the Job itself was killed (for example out of memory), the runner starts a short rollback Job to lift the write pause.

The work runs in a short-lived Job in the namespace, using the image you pass (official `postgres` or `postgis/postgis` from Docker Hub). The Job reads the credentials from the namespace Secret, so the action never sees or prints them. If a NetworkPolicy already isolates a database pod, the action adds a temporary one that lets this run's Job pods connect, and removes it afterwards. It adds none to a pod that no policy isolates, because the first policy on a pod would block its other clients. The Job and its log are kept for a day.

### Rehearsal

`mode: rehearse` copies the source into a throwaway server of the new major inside the Job pod and runs the same checks. It never pauses writes and changes nothing, so it is safe against TEST or PROD at any time.

### Adoption pattern

1. **Pull request: rehearse against a copy of TEST data.** The PR workflow rehearses with TEST's database as the source. The Job restores a copy of TEST data into the new major and verifies it; TEST itself is only read. A failure here blocks the PR before anything is deployed. The PR environment's own database is new, so its deploy reports `skipped`.
2. **TEST: rehearse, then upgrade.** After merge, the TEST deploy rehearses once more against TEST's current data, then runs the real upgrade, and the backend switches to the new database.
3. **PROD: upgrade.** The PROD deploy runs the upgrade only after TEST has upgraded and the app has been checked there. Each run's job summary shows the copy time (how long writes were paused) and the Job's peak memory; use TEST's numbers to set `timeout` and `memory_limit` for PROD.

## Usage

The examples follow [bcgov/quickstart-openshift](https://github.com/bcgov/quickstart-openshift), moving its `common/openshift.database.yml` StatefulSet from PostgreSQL 17 to 18. The new database gets its own name, so the old StatefulSet and its volume stay as they are.

### Deploy: `.github/workflows/reusable-deploy.yml`

The upgrade must finish before the backend points at the new database, so the database leaves the deploy matrix and the backend and frontend wait for the upgrade:

```yaml
  database:
    name: Deploy (database)
    environment: ${{ inputs.environment }}
    needs: [init]
    runs-on: ubuntu-24.04
    steps:
      - uses: bcgov/action-deployer-openshift@e2d60eb9cacceb89c3b97d8dcf0a2c460eea5eab # v4.2.3
        with:
          file: common/openshift.database.yml
          oc_namespace: ${{ secrets.oc_namespace }}
          oc_server: ${{ vars.oc_server }}
          oc_token: ${{ secrets.oc_token }}
          parameters: -p ZONE="${{ inputs.target }}"
            -p NAME="${{ github.event.repository.name }}"
            -p COMPONENT=database-18 -p PG_VERSION=18 -p DB_PVC_SIZE="256Mi"
          triggers: ${{ inputs.triggers }}

  database-upgrade:
    name: Database upgrade
    environment: ${{ inputs.environment }}
    needs: [database]
    runs-on: ubuntu-24.04
    timeout-minutes: 35
    steps:
      # Adoption step 2: TEST rehearses again before its real upgrade
      - if: inputs.target == 'test'
        uses: bcgov/actions-openshift/pg-upgrade@vX.Y.Z
        with:
          mode: rehearse
          source: ${{ github.event.repository.name }}-${{ inputs.target }}-database
          secret: ${{ github.event.repository.name }}-${{ inputs.target }}-database
          image: postgres:18
          app_label: ${{ github.event.repository.name }}-${{ inputs.target }}
          oc_namespace: ${{ secrets.oc_namespace }}
          oc_server: ${{ vars.oc_server }}
          oc_token: ${{ secrets.oc_token }}

      - uses: bcgov/actions-openshift/pg-upgrade@vX.Y.Z
        with:
          source: ${{ github.event.repository.name }}-${{ inputs.target }}-database
          target: ${{ github.event.repository.name }}-${{ inputs.target }}-database-18
          secret: ${{ github.event.repository.name }}-${{ inputs.target }}-database
          image: postgres:18
          app_label: ${{ github.event.repository.name }}-${{ inputs.target }}
          oc_namespace: ${{ secrets.oc_namespace }}
          oc_server: ${{ vars.oc_server }}
          oc_token: ${{ secrets.oc_token }}

  deploy:
    name: Deploy (${{ matrix.name }})
    needs: [init, database-upgrade]
    # matrix: backend and frontend, as before
```

`COMPONENT=database-18` renames only the StatefulSet and Service; the template still reads the `${NAME}-${ZONE}-database` Secret, so the user, password and database name carry over. In the same pull request:

* `backend/openshift.deploy.yml`: change the database host `${NAME}-${ZONE}-database` (the wait loop and the JDBC URL) to `${NAME}-${ZONE}-database-18`.
* `common/openshift.init.yml`: add a NetworkPolicy like `${NAME}-${ZONE}-database-ingress` for pods labelled `deployment: ${NAME}-${ZONE}-database-18`, so the backend can reach the new database. The Job's own access is temporary and handled by the action.

A new PR environment has no old database, so the step reports `skipped` and the new database starts empty.

### Rehearsal on a copy of TEST data: `.github/workflows/pr-open.yml`

Adoption step 1:

```yaml
  database-rehearsal:
    name: Database upgrade rehearsal (TEST data)
    environment: test
    runs-on: ubuntu-24.04
    timeout-minutes: 35
    steps:
      - uses: bcgov/actions-openshift/pg-upgrade@vX.Y.Z
        with:
          mode: rehearse
          source: ${{ github.event.repository.name }}-test-database
          secret: ${{ github.event.repository.name }}-test-database
          image: postgres:18
          oc_namespace: ${{ secrets.oc_namespace }}
          oc_server: ${{ vars.oc_server }}
          oc_token: ${{ secrets.oc_token }}
```

Add `database-rehearsal` to the `needs` of `results` (PR Results). The `test` environment must allow pull request runs. In `merge.yml` nothing changes: `deploy-test` rehearses and upgrades TEST (step 2), then `deploy-prod` upgrades PROD (step 3).

### Deployments

An older template that runs the database as a Deployment works the same way: deploy the new major as a StatefulSet like quickstart's, under a new name, and set `source` to the old Deployment's Service. The old Deployment and its PVC stay untouched.

### PostGIS

Use the `postgis/postgis` image for the new major, with the PostGIS version your target runs, e.g. `image: postgis/postgis:18-3.6`. The extension is created at the target's version during the restore.

### Renovate

The image tag in these workflows is the one to bump. A Renovate major bump only happens if the repo's Renovate config allows PostgreSQL majors. Changing the major also needs a new database name (`COMPONENT` above), so it is always a reviewed pull request.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `source` | yes | | Service of the old database |
| `secret` | yes | | Secret with `database-name`, `database-user`, `database-password` |
| `oc_namespace`, `oc_server`, `oc_token` | yes | | OpenShift login, as for [oc-runner](../oc-runner) |
| `target` | for `upgrade` | `""` | Service of the new, empty database |
| `image` | yes | | `postgres:<tag>` or `postgis/postgis:<tag>` from Docker Hub, matching the target's major |
| `mode` | | `upgrade` | `upgrade`, `rehearse` or `rollback` |
| `app_label` | | `""` | `app` label for the Job, NetworkPolicies and ConfigMap, so PR cleanup removes them |
| `target_secret` | | `secret` | Secret for the target, if different (same keys) |
| `memory_limit` | | `1Gi` | Memory limit of the Job pod, at least `256Mi` |
| `timeout` | | `30m` | Time for the whole step; the Job gets one minute less |

The source user must own the source database (or be a superuser) to pause writes, and the target user must be able to create the source's extensions (the official images' `POSTGRES_USER` is a superuser). Objects are restored with `--no-owner --no-privileges`, owned by the target user. The Job keeps the compressed dump on its `emptyDir` volume, and a rehearsal also keeps a full copy there.

## Outputs

| Output | Values |
| --- | --- |
| `result` | `upgraded`, `already-upgraded`, `rehearsed`, `rolled-back`, or `skipped` (no source Service) |
| `copy_seconds` | Seconds from the start of the copy to the verified commit. For `upgrade` this is how long writes were paused |
| `peak_memory_mib` | The Job container's peak working set (memory in use minus reclaimable page cache, as `oc adm top` shows it), sampled every second, for sizing `memory_limit` |
| `rows` | Rows copied and verified across all tables |

The last three are empty when nothing was copied. The same numbers, with the source and dump sizes, go in the job summary.

## Tested versions

CI in this repo, on every pull request and nightly (3:17 AM PDT, 2:17 AM PST):

* **Containers:** every source major from 13 to 17 upgraded to quickstart-openshift's major (17) and to the newest `postgres` major on Docker Hub, found from its tags on each run, so a new release is tested the night it appears. Each pair runs the full set of checks, with `postgis/postgis` pairs at the newest PostGIS for each major. A brand-new major is tested for PostGIS once `postgis/postgis` publishes it.
* **Cluster:** PostgreSQL 13 to 17 through rehearse, upgrade, repeat and rollback; and a PostGIS 13 to newest-major upgrade of a large dataset (points, polygons and lines with GiST indexes, a million-row table and 512 KB values), sized to the namespace quota, with counts, content hashes and spatial queries compared on both sides.

The action also accepts sources from PostgreSQL 10 to 12, which CI doesn't test.

## Rollback

1. Revert the pull request that switched the app, so the backend points at the old database again.
2. Run the action with `mode: rollback` (same `source`, `target`, `secret` and `image`), e.g. from a `workflow_dispatch` workflow. It waits for no upgrade to be running. It makes the old database writable again and removes the `<target>-pg-upgrade` record.

The old database holds the data as it was when writes were paused. Rows written to the new database after the switch exist only there. Before upgrading again, delete the new database's StatefulSet and PVC, because the action only copies into an empty database. Remove the old database in a later cleanup, once the upgrade has run in PROD.

## Not covered

* **Helm charts:** charts that expose the database through a Service with a selector and a Secret with the keys above fit as they are. Others need the Secret key names as inputs, which this action doesn't take yet.
* **Crunchy (PGO):** use Crunchy's own major upgrade (`PGUpgrade`), not this action.
* **Manual fallback:** [bcgov/devops-scripts](https://github.com/bcgov/devops-scripts) `oc/db_transfer.sh` and `oc/db_compare.sh`.
