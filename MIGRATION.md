# Migration guide

Caller-facing changes in actions-openshift for v1.0.0. Shared rules (trigger and list formats, booleans, `diff_base`, `debug`) are explained in the [bcgov/actions migration guide](https://github.com/bcgov/actions/blob/main/MIGRATION.md), and this repo's input errors link there. Before v1.0.0, renames have no aliases: GitHub warns `Unexpected input` and the new input keeps its default.

- [diff_base](#diff_base)
- [debug](#debug)
- [login_attempts](#login_attempts)
- [Booleans](#booleans)
- [Lists](#lists)
- [crunchy outputs](#crunchy-outputs)
- [Finding affected callers](#finding-affected-callers)

## diff_base

**Actions:** `oc-runner` (`diff_branch`), `deployer` (`ref`), `crunchy` (`diff_branch`). **Shared rule:** [bcgov/actions#diff_base](https://github.com/bcgov/actions/blob/main/MIGRATION.md#diff_base).

**Before:**

```yaml
- uses: bcgov/actions-openshift/deployer@<sha> # v0.5.0
  with:
    triggers: backend/
    ref: main
```

**After:** `diff_base` everywhere. `ref` keeps the actions/checkout meaning (oc-runner and crunchy use it for the repository they check out).

```yaml
- uses: bcgov/actions-openshift/deployer@<sha> # v1.0.0
  with:
    triggers: backend/
    diff_base: main
```

**Why:** one name for the diff base, matching bcgov/actions, and no `ref` that means two things.

## debug

**Action:** `oc-runner`. **Shared rule:** [bcgov/actions#debug](https://github.com/bcgov/actions/blob/main/MIGRATION.md#debug).

**Before:**

```yaml
verbose: true
```

**After:**

```yaml
debug: true
```

**Why:** every action calls its debug switch `debug`; a run re-run with debug logging turns it on too. deployer's `debug: false` now really is off (`if: inputs.debug` used to be true for the string `"false"`).

## login_attempts

**Actions:** `oc-runner`, `deployer`.

**Before:**

```yaml
login_attempts: 2
```

**After:** removed; delete the line. Login always retries once.

**Why:** it was capped at 2 anyway: a blocked runner IP stays blocked, so more attempts only burn minutes.

## Booleans

**Actions:** `deployer` (`debug`, `overwrite`, `lite_mode`), `crunchy` (`route_enabled`, `standby_enabled`, `shutdown`, `dry_run`, `self_heal_stuck_releases`, `force_cleanup`), `route-tls` (`dry_run`). **Shared rule:** [bcgov/actions#boolean-and-enum-inputs](https://github.com/bcgov/actions/blob/main/MIGRATION.md#boolean-and-enum-inputs).

`true` or `false` (any case); anything else fails. cleanup-pr `cleanup` must be `helm` or `label`. deployer `overwrite` still defaults to `true`; `lite_mode` defaults to `true` on pull_request events.

```yaml
dry_run: true
```

## Lists

**Actions:** `cleanup-pr` (`cleanup_name`, `remove_pvc`), `sysdig-monitor` (`components`). **Shared rule:** [bcgov/actions#list-inputs](https://github.com/bcgov/actions/blob/main/MIGRATION.md#list-inputs).

**Before:** `cleanup_name` was space separated.

```yaml
cleanup_name: app-a app-b
```

**After:** one per line, comma separated, or a JSON array.

```yaml
cleanup_name: app-a, app-b
```

**Why:** the same list rules as every bcgov/actions action. cert-expiry `hosts` is unchanged.

## crunchy outputs

**Action:** `crunchy`.

**Before:**

```yaml
parameters: -p DB_SECRET=${{ steps.crunchy.outputs.db_secret }} -p DB_HOST=${{ steps.crunchy.outputs.db_host }}
```

**After:** the libpq connection keywords: `db_host` → `host`, `db_port` → `port`, `db_user` → `user`, `db_name` → `dbname`, `db_secret` → `secret`. `release` and `cluster` are unchanged.

```yaml
parameters: -p DB_SECRET=${{ steps.crunchy.outputs.secret }} -p DB_HOST=${{ steps.crunchy.outputs.host }}
```

**Why:** standard Postgres names, without a prefix that repeats the action's purpose.

## Finding affected callers

```bash
grep -rnE \
  -e '^\s+(verbose|diff_branch|login_attempts):' \
  -e 'outputs\.db_(host|port|user|name|secret)' \
  -e 'cleanup_name:\s*[^,]+\s[^,]+$' \
  .github/
```

Also check `ref:` on deployer steps (now `diff_base:`); `ref:` on actions/checkout, oc-runner and crunchy stays. For bcgov/actions changes, run the grep in [its guide](https://github.com/bcgov/actions/blob/main/MIGRATION.md#finding-affected-callers).
