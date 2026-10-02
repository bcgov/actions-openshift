# AGENTS.md

Repository facts for automated coding assistants. Teams may edit or remove this file.

## Layout
- Composite actions: `cleanup-pr/`, `crunchy/`, `deployer/`, `oc-runner/`, `route-tls/`
- Helm chart: `crunchy/charts/crunchy` (`crunchy/values.yml`). OpenShift templates: `deployer/templates/`, `oc-runner/cronjob/openshift.deploy.yml`
- Workflows: `.github/workflows/` (checks: `pr-open.yml`, `pr-close.yml`, `oc-runner-commands.yml`; reusable: `.deployer.yml`, `.pr-close.yml`, `.schema-spy.yml`)
- Tests: `.github/tests/` (bats). Script-injection audit: `scripts/audit_composite_actions.py`

## Build, test, deploy
- No package build. Lint workflows: `docker run --rm -v "$(pwd)":/repo -w /repo rhysd/actionlint:latest`. Audit: `python3 scripts/audit_composite_actions.py`
- Unit tests: `bats .github/tests/crunchy .github/tests/route-tls` and `bats .github/tests/oc-runner`. Chart: `helm lint crunchy/charts/crunchy --values crunchy/values.yml`
- OpenShift deploys run from GitHub Actions, not a workstation. Same-repo pull requests exercise deployer and route-tls; `pr-close.yml` removes the deployer test resources. Workstation scripts live in [bcgov/devops-scripts](https://github.com/bcgov/devops-scripts)

## Shared actions
- Call a sibling action as `$/<name>`, never `./`. Use bcgov shared actions (`bcgov/actions/*`, `bcgov/action-*`) as provided; don't copy or fork them.
- Never pin `@main`. Pin bcgov shared actions to a published release SHA with a `# vX.Y.Z` comment.
