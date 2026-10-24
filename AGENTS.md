# AGENTS.md

Repository facts and constraints for automated coding assistants.

## Layout
- Composite actions: `cert-expiry/`, `cleanup-pr/`, `crunchy/`, `deployer/`, `image-import/`, `oc-runner/`, `pg-upgrade/`, `route-tls/`, `sysdig-monitor/`
- Helm chart: `crunchy/charts/crunchy` (`crunchy/values.yml`). OpenShift templates: `deployer/templates/`, `oc-runner/cronjob/openshift.deploy.yml`
- Workflows: `.github/workflows/` (checks: `pr-open.yml`, `pr-close.yml`, `cert-expiry-tests.yml`, `oc-runner-commands.yml`, `pg-upgrade.yml`; reachability records: `probe-runner-reachability.yml`, weekly report `probe-runner-report.yml`; reusable: `.deployer.yml`, `.pr-close.yml`, `.schema-spy.yml`)
- Tests: `.github/tests/` (bats). Script-injection audit: `scripts/audit_composite_actions.py`

## Build, test, deploy
- No package build. Lint workflows: `docker run --rm -v "$(pwd)":/repo -w /repo rhysd/actionlint:latest`. Audit: `python3 scripts/audit_composite_actions.py`. ShellCheck: `shellcheck --severity=warning` on `*.sh` (except `crunchy/`) and `python3 scripts/shellcheck_composite_actions.py`
- Unit tests: `bats .github/tests/*`. Chart: `helm lint crunchy/charts/crunchy --values crunchy/values.yml`
- OpenShift deploys run from GitHub Actions, not a workstation. Same-repo pull requests exercise deployer and route-tls; `pr-close.yml` removes the deployer test resources. Workstation scripts live in [bcgov/devops-scripts](https://github.com/bcgov/devops-scripts)

## Inputs and outputs

- Read list, boolean, enum and debug inputs through `shared/inputs.sh` (same rules as bcgov/actions `shared/inputs.js`: lists are one item per line or a single value; booleans true/false; bad values fail with an annotation). It is this repo's own helper, not a copy of a bcgov/actions action.
- `ref` keeps the actions/checkout meaning (what to check out). `base` is the base triggers are diffed against (dorny/paths-filter `base`). `debug` is the debug switch; `token` defaults to `github.token`. Names are snake_case.
- Outputs: booleans `true`/`false`; lists are JSON arrays.

## Shared actions
- Call a sibling action as `$/<name>`, never `./`. Use bcgov shared actions (`bcgov/actions/*`) as provided; don't copy or fork them.

## Action Architecture & Rules

- **`route-tls` is standalone only**: When assisting downstream repositories with custom vanity Route TLS, always implement it as an independent on-demand workflow (`.github/workflows/route-tls.yml` on `workflow_dispatch` with `dry_run` choice defaulting to `true`). **NEVER** embed `route-tls` into `merge.yml`, `release.yml`, or continuous deployment pipelines.
- **Secret Management**: Certificates belong in the `prod` GitHub Environment (`TLS_CERTIFICATE`, `TLS_PRIVATE_KEY`, `TLS_CA_CERTIFICATE`). Automated assistants must never manage secrets directly; draft copy-pasteable `gh secret set` commands in chat for human maintainers.
- **Entrust Certificate Mapping**:
  - `TLS_CERTIFICATE`: leaf only (`<host>.pem`).
  - `TLS_PRIVATE_KEY`: unencrypted private key (`<host>.key`).
  - `TLS_CA_CERTIFICATE`: issuing intermediate only (`Entrust OV TLS Issuing RSA CA 2.pem`). Exclude root CAs and `.csr`.
- **Runtime**: Choose bash or JavaScript from the action's job. Bash calls `oc` and `openssl`. JavaScript or TypeScript fits a GitHub API client, pagination, or JSON assembly. Pick whichever implementation is smaller.
- **Pinning**: Pin third-party actions to full 40-character commit SHAs with `# vX.Y.Z` trailing comments. Never pin `@main`. Pin bcgov shared actions (`bcgov/actions/*`) to a published release SHA with a `# vX.Y.Z` comment.
- **PR triggers**: PR workflows must not fire unnecessarily. Gate heavy jobs (matrices, container tests, deploys) with job-level `bcgov/actions/diff-triggers` or path filters that list only the files each job depends on, never a whole action folder with its README. Markdown and docs-only changes never start heavy jobs. Skipped jobs still report through `bcgov/actions/workflow-results` with the standard job names and no `title`, so required checks stay stable; a top-level `paths` filter hides the whole workflow, so avoid it where checks are required.

## README usage examples

- Usage examples in action READMEs show how `bcgov/quickstart-openshift` would call the action: its workflows (`pr-open.yml`, `pr-close.yml`, `merge.yml`, `scheduled.yml`), its packages (`backend`, `frontend`, `migrations`) and its job order. Add a separate example only when the quickstart shape does not fit. Never say quickstart uses an action it does not use; read its workflows first.

## bcgov/actions dependency

- `deployer`, `crunchy`, and `oc-runner` call `bcgov/actions/diff-triggers`; `.github/workflows/.deployer.yml` calls `bcgov/actions/image-tracker`; repo workflows call `bcgov/actions/diff-triggers` and `bcgov/actions/workflow-results`. All `bcgov/actions/*` references are pinned to the same suite release SHA.
- Each rollout wave includes the entire suite: release `bcgov/actions` first, bump all `bcgov/actions/*` pins here, then release `bcgov/actions-openshift` so consumer waves update both suites together.
