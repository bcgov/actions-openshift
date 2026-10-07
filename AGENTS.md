# AGENTS.md

Repository facts and constraints for automated coding assistants.

## Layout
- Composite actions: `cleanup-pr/`, `crunchy/`, `deployer/`, `oc-runner/`, `route-tls/`
- Helm chart: `crunchy/charts/crunchy` (`crunchy/values.yml`). OpenShift templates: `deployer/templates/`, `oc-runner/cronjob/openshift.deploy.yml`
- Workflows: `.github/workflows/` (checks: `pr-open.yml`, `pr-close.yml`, `oc-runner-commands.yml`; reachability: `probe-runner-reachability.yml`; reusable: `.deployer.yml`, `.pr-close.yml`, `.schema-spy.yml`)
- Tests: `.github/tests/` (bats). Script-injection audit: `scripts/audit_composite_actions.py`

## Build, test, deploy
- No package build. Lint workflows: `docker run --rm -v "$(pwd)":/repo -w /repo rhysd/actionlint:latest`. Audit: `python3 scripts/audit_composite_actions.py`
- Unit tests: `bats .github/tests/crunchy .github/tests/route-tls` and `bats .github/tests/oc-runner`. Chart: `helm lint crunchy/charts/crunchy --values crunchy/values.yml`
- OpenShift deploys run from GitHub Actions, not a workstation. Same-repo pull requests exercise deployer and route-tls; `pr-close.yml` removes the deployer test resources. Workstation scripts live in [bcgov/devops-scripts](https://github.com/bcgov/devops-scripts)

## Shared actions
- Call a sibling action as `$/<name>`, never `./`. Use bcgov shared actions (`bcgov/actions/*`, `bcgov/action-*`) as provided; don't copy or fork them.

## Action Architecture & Rules

- **`route-tls` is standalone only**: When assisting downstream repositories with custom vanity Route TLS, always implement it as an independent on-demand workflow (`.github/workflows/route-tls.yml` on `workflow_dispatch` with `dry_run` choice defaulting to `true`). **NEVER** embed `route-tls` into `merge.yml`, `release.yml`, or continuous deployment pipelines.
- **Secret Management**: Certificates belong in the `prod` GitHub Environment (`TLS_CERTIFICATE`, `TLS_PRIVATE_KEY`, `TLS_CA_CERTIFICATE`). Automated assistants must never manage secrets directly; draft copy-pasteable `gh secret set` commands in chat for human maintainers.
- **Entrust Certificate Mapping**:
  - `TLS_CERTIFICATE`: leaf only (`<host>.pem`).
  - `TLS_PRIVATE_KEY`: unencrypted private key (`<host>.key`).
  - `TLS_CA_CERTIFICATE`: issuing intermediate only (`Entrust OV TLS Issuing RSA CA 2.pem`). Exclude root CAs and `.csr`.
- **Bash over JavaScript**: Actions in this repository stay in bash (`openssl` + `oc`). Do not rewrite composite actions to Node.js or JavaScript.
- **Pinning**: Pin third-party actions to full 40-character commit SHAs with `# vX.Y.Z` trailing comments. Never pin `@main`. Pin bcgov shared actions (`bcgov/actions/*`, `bcgov/action-*`) to a published release SHA with a `# vX.Y.Z` comment.
