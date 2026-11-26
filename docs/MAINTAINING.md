# Maintaining `bcgov/actions-openshift`

Guide for repository maintainers covering releases, downstream rollout, and common pitfalls.

## Cutting a release

All composite actions and reusable workflows in this repository share one SemVer release tag (`vX.Y.Z`). Unlike `bcgov/actions`, this repository ships composite bash and YAML directly from `main`—there is no `dist/` build step or double-tag release workflow.

1. Confirm `main` is green across the push-triggered workflows (`pr-open.yml` and the action test workflows in [`.github/workflows/`](../.github/workflows/)).
2. Open the [New Release page](../../../releases/new).
3. Enter a new `vX.Y.Z` tag targeting `main` (tip of `main`), generate or review the release notes, and publish the release.
4. Use the `main` commit SHA of the new tag when updating consumer pins (`<40-char-sha> # vX.Y.Z`).
5. If a regression is found after publishing, **do not delete or reuse `vX.Y.Z`**. Fix the issue on `main` and publish the next patch version (`vX.Y.(Z+1)`).

## How canaries and consumers pick up changes

Downstream repositories pin releases by full 40-character commit SHA with a `# vX.Y.Z` comment—never `@main` and never an unpinned tag ([ADR 0002](adr/0002-consumer-sha-pinning.md)).

Rollout order across the suite ([ADR 0003](adr/0003-bcgov-actions-relationship.md)):

1. **Release `bcgov/actions` first** (when general actions also changed; wait for its Release workflow to finish before copying its tag SHA).
2. **Update and release `bcgov/actions-openshift`**: bump every `bcgov/actions/*` pin (across `*/action.yml` and `.github/workflows/*.yml`) to the single new `bcgov/actions` release SHA, merge to `main`, and publish `vX.Y.Z`.
3. **Canaries**: update designated canary repositories first (such as `bcgov/nr-forest-client-commons` and `bcgov/nr-old-growth`, and verify alignment with `bcgov/quickstart-openshift` workflow patterns) and confirm their runs succeed.
4. **Renovate consumers**: repositories extending `bcgov/renovate-config` receive automated SHA-pin bump PRs from Renovate once `vX.Y.Z` is published. Because Renovate does not gate PRs on canary health, maintainers should verify canary runs promptly after releasing.

## Common pitfalls

- **Using `./` instead of `$/` for sibling actions:** Composite actions that call another action in this repository must use `uses: $/<action>`. Relative `./` fails for external callers, and `pr-open.yml` enforces `$/` on every pull request.
- **Partial `bcgov/actions/*` pin bumps:** Every action and workflow in this repository pins the same `bcgov/actions` release SHA. Update all `*/action.yml` and `.github/workflows/*.yml` files (including `.deployer.yml`) together.
- **Undeclared inputs fail fast (`input-enforcer`):** Every composite action runs `bcgov/actions/input-enforcer` at its first step and fails immediately on any unknown `with:` key (`expected-failure-tests.yml` verifies this across all `*/action.yml`). Keep caller examples and workflow inputs aligned with declared inputs.
- **Strict input formatting ([`shared/inputs.sh`](../shared/inputs.sh)):** List inputs accept one item per line (multiline YAML string) or a single value—JSON arrays, parenthesized lists, or comma/space-separated items fail with an error annotation. Booleans accept only `true` or `false`.
- **Path filters and required checks (`diff-triggers` + `workflow-results`):** PR workflows use job-level `diff-triggers` with `!*.md` so documentation edits do not run heavy container tests or OpenShift deploys while `workflow-results` still reports stable check names. When adding or renaming scripts or tests, update the matching `.github/workflows/*-tests.yml` `triggers:` list, and avoid top-level `paths:` filters on required PR workflows.
- **Embedding `cert-keeper` in CD pipelines:** `cert-keeper` must run only as a standalone workflow per repository—never inside `merge.yml`, `release.yml`, or deploy workflows ([ADR 0001](adr/0001-cert-keeper-per-repo.md)). Use a daily `schedule` for Let's Encrypt renewals, and on-demand `workflow_dispatch` for pre-supplied certificates.
- **Same-repo vs. fork PR checks:** Same-repo PRs run OpenShift integration checks (cleaned up by `pr-close.yml`), whereas fork PRs run without secrets and are verified by `test-fork-token-degradation` in `pr-open.yml`.
