# ADR 0002: Release versioning and consumer SHA pinning

## Status

Accepted

## Context

Consuming `bcgov` repositories run `bcgov/actions-openshift` composite actions and reusable workflows inside CI/CD jobs that hold OpenShift deployment tokens and secrets. Pointing workflows at mutable references such as `@main` or moving version tags exposes downstream pipelines to unreviewed upstream changes and breaks reproducible runs.

## Decision

1. All composite actions and reusable workflows in `bcgov/actions-openshift` are versioned and released together under a single SemVer suite tag (`vX.Y.Z`) on `main`.
2. Consuming repositories pin every `uses:` reference to the full 40-character commit SHA of a published release, annotated with a trailing `# vX.Y.Z` comment, and never reference `@main` or an unpinned tag.
3. Internal workflows and composite actions inside `bcgov/actions-openshift` reference sibling actions using `$/<action>` (never `./`) so pull requests execute the checked-out commit while remaining valid when called externally.
4. Automated pin updates in consumer repositories are delivered via Renovate (extending `bcgov/renovate-config`), coordinated with canary validation by maintainers.

## Consequences

- Downstream workflows remain immutable against commits on `main` until an explicit SHA-pin update PR is reviewed and merged.
- Any breaking change to an action or reusable workflow requires a suite major bump (or minor bump while `0.x`) unless backward compatibility is preserved.
- Published release tags on `main` must not be deleted or rewritten so Renovate's `# vX.Y.Z` tag-to-SHA resolution stays consistent across consumers.
