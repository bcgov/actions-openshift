# ADR 0003: Relationship and release coupling with `bcgov/actions`

## Status

Accepted

## Context

The shared GitHub Actions platform is split into two versioned monorepos ([`bcgov/actions` ADR 0003](https://github.com/bcgov/actions/blob/main/docs/adr/0003-action-suite-consolidation.md)): `bcgov/actions` for general CI, build, scanning, and workflow coordination, and `bcgov/actions-openshift` for OpenShift deployment, database, and certificate automation. Because `bcgov/actions-openshift` actions and workflows depend directly on primitives from `bcgov/actions`, uncoordinated updates or duplicated helpers create drift between the two suites.

## Decision

1. `bcgov/actions` remains the canonical home for general CI primitives (`input-enforcer`, `diff-triggers`, `image-tracker`, `workflow-results`), while `bcgov/actions-openshift` owns OpenShift-specific actions and reusable workflows.
2. `bcgov/actions-openshift` consumes `bcgov/actions/*` actions directly rather than copying or forking them. All `bcgov/actions/*` references across `*/action.yml` and `.github/workflows/*.yml` stay pinned to a single `bcgov/actions` suite release SHA.
3. Suite releases follow a fixed dependency order: release `bcgov/actions` first, update all `bcgov/actions/*` pins in `bcgov/actions-openshift` to that release SHA, and then release `bcgov/actions-openshift` so downstream consumers can update both suites together.
4. Where bash execution requires local input validation, [`shared/inputs.sh`](../../shared/inputs.sh) mirrors the strict list, boolean, enum, and debug parsing rules of `bcgov/actions` `shared/inputs.js`.

## Consequences

- Input validation (`input-enforcer` and `shared/inputs.sh`), diff filtering (`diff-triggers`), and required-check reporting (`workflow-results`) behave consistently across both repositories.
- Maintainers release `bcgov/actions` (waiting for its release workflow to finish) before bumping `bcgov/actions/*` pins in `bcgov/actions-openshift`.
- Pin-bump PRs in `bcgov/actions-openshift` must update all composite actions and workflows together rather than leaving mixed `bcgov/actions` SHAs.
