<!-- Badges -->
[![Issues](https://img.shields.io/github/issues/bcgov/actions-openshift)](/../../issues)
[![Pull Requests](https://img.shields.io/github/issues-pr/bcgov/actions-openshift)](/../../pulls)
[![MIT License](https://img.shields.io/github/license/bcgov/actions-openshift.svg)](/LICENSE)
[![Lifecycle](https://img.shields.io/badge/Lifecycle-Experimental-339999)](https://github.com/bcgov/repomountie/blob/master/doc/lifecycle-badges.md)

<!-- Reference-Style link -->
[issues]: https://docs.github.com/en/issues/tracking-your-work-with-issues/creating-an-issue
[pull requests]: https://docs.github.com/en/desktop/contributing-and-collaborating-using-github-desktop/working-with-your-remote-repository-on-github-or-github-enterprise/creating-an-issue-or-pull-request

# OpenShift CLI (oc) Login and Runner

Action for running oc commands. Intended for use with the BC Government's OpenShift cluster.  We will do our best to keep the default oc runner version lined up with whatever the platform team currently has deployed to production.

Provide as few as zero commands to login only.  There is a separate parameter for cronjobs, with the ability to report success or failure.

# Usage

```yaml
- uses: bcgov/actions-openshift/oc-runner@vX.Y.Z
  with:
    ### Required
    
    # OpenShift project/namespace
    oc_namespace: abc123-dev

    # OpenShift server
    oc_server: https://api.silver.devops.gov.bc.ca:6443
    
    # OpenShift token
    # Usually available as a secret in your project/namespace
    oc_token: ${{ secrets.OC_TOKEN }}


    ### Typical / recommended

    # Command to run, generally oc commands
    commands: oc whoami

    # Cronjob to run and report on
    cronjob: repo-name-cronjob-etc

    # Bash array to diff for triggering; omit to always run
    triggers: ('frontend/' 'backend/' 'database/')


    ### Usually a bad idea / not recommended

    # Number of cronjob log lines to tail; use -1 for all
    cronjob_tail: 0

    # Overrides the default branch to diff against
    diff_branch: ${{ github.event.repository.default_branch }}

    # Override GitHub default oc version >= 4.0
    oc_version: "4.14"

    # Override repository to clone
    repository: ${{ github.repository }}

    # Override branch, tag or SHA to clone; omit to use the default branch
    ref: ''

    # Time limit for the commands block, and separately for the cronjob wait; e.g. 10m
    timeout: 10m

    # Enable verbose command tracing with bash xtrace (set -x)
    verbose: false

    # Maximum number of login attempts; values above 2 are capped at 2 (one retry)
    login_attempts: 2
```

# Example: Login only

Login only.

```yaml
login:
  name: Login Only
  runs-on: ubuntu-24.04
  steps:
    - uses: bcgov/actions-openshift/oc-runner@vX.Y.Z
      with:
        oc_namespace: ${{ vars.oc_namespace }}
        oc_server: ${{ vars.oc_server }}
        oc_token: ${{ secrets.OC_TOKEN }}
```

# Example: Run Multiple Commands Conditionally (w/ Triggers)

Run multiple commands if any trigger files/paths have changes.  Triggers are optional.

```yaml
whoareyou:
  name: Who Are You?
  runs-on: ubuntu-24.04
  steps:
    - uses: bcgov/actions-openshift/oc-runner@vX.Y.Z
      with:
        oc_namespace: ${{ vars.oc_namespace }}
        oc_server: ${{ vars.oc_server }}
        oc_token: ${{ secrets.OC_TOKEN }}
        triggers: ('frontend/' 'backend/' 'database/')
        commands: |
          oc whoami
          oc version
```

# Example: Run and Report on Cronjob (w/ Triggers)

Provide the name of a cronjob object.  It will be run timestamped and return a success or failure on completion.  Triggers are optional.

```yaml
cronjob:
  name: Run and Report on Cronjob
  runs-on: ubuntu-24.04
  steps:
    - uses: bcgov/actions-openshift/oc-runner@vX.Y.Z
      with:
        oc_namespace: ${{ vars.oc_namespace }}
        oc_server: ${{ vars.oc_server }}
        oc_token: ${{ secrets.OC_TOKEN }}
        triggers: ('cronjobland/' 'misc/' 'whatever/')
        cronjob: repo-name-cronjob-etc
```

# Output

This action returns:

- `triggered`: boolean (`'true'` or `'false'`) indicating whether trigger paths changed
- `commands`: generic command output channel from the `commands` step (usually empty unless explicitly set)

`commands` is expected to be empty in most runs. To populate it, write to `$GITHUB_OUTPUT` inside your `commands` input. Plain text lines are automatically mapped to the `commands` output (you do not need to prefix with `commands=`). Existing `commands=<value>` usage is still supported.

```yaml
jobs:
  command:
    runs-on: ubuntu-latest
    outputs:
      triggered: ${{ steps.oc.outputs.triggered }}
      commands: ${{ steps.oc.outputs.commands }}
    steps:
      - id: oc
        uses: bcgov/actions-openshift/oc-runner@vX.Y.Z
        with:
          oc_namespace: ${{ vars.oc_namespace }}
          oc_server: ${{ vars.oc_server }}
          oc_token: ${{ secrets.OC_TOKEN }}
          commands: |
            oc whoami
            echo "$(oc whoami)" >> "$GITHUB_OUTPUT"

  result:
    runs-on: ubuntu-latest
    needs: [command]
    steps:
      - run: |
          echo "Triggered = ${{ needs.command.outputs.triggered }}"
          echo "Command output = ${{ needs.command.outputs.commands }}"
```

# OpenShift Login Retry and Fail-Fast Behavior

To handle transient network drops, cluster API restarts, or runner configuration mistakes, the action implements validation gates and retry logic:
- **Pre-flight Reachability Check:** Before downloading `oc`, logging in or running any commands, the action sends an unauthenticated request to the API's `/version` (10-second timeout, TLS verified). Any HTTP response, including `401`/`403`, means the API is reachable and the job continues. If the connection is refused or times out, the action probes the same cluster's router (`api.<cluster>.devops.gov.bc.ca` maps to `console.apps.<cluster>.devops.gov.bc.ca`, e.g. gold, silver, golddr; if `oc_server` doesn't match that pattern, it logs a notice and uses silver's router), logs the runner's public IP and fails immediately with one of:
  - `Cluster is up (the <cluster> router answered), but this runner's IP (x.x.x.x) is blocked from the OpenShift API (...). Re-run the job to get a different runner.` The router answered, so the cluster is up but this GitHub-hosted runner's IP is blocked by the firewall. Re-running the job usually lands on a runner with a different IP.
  - `OpenShift is unreachable from this runner (IP x.x.x.x): neither the API (...) nor the <cluster> router answered.` The cluster or the network may be down; re-run later.
- **Early Input Validation:** Before executing any login attempts or downloading tools, the action validates that `oc_server`, `oc_namespace`, and `oc_token` are populated and that the server URL is properly formatted. If inputs are missing or malformed, the action fails fast immediately to prevent useless retries.
- **Fail Fast:** If the OpenShift API returns a non-retryable client error (such as `401 Unauthorized`, `403 Forbidden`, or `404 Not Found`), the action aborts immediately on the first attempt to save runner billing minutes.
- **Retry:** If the connection times out at the network layer (HTTP status `000`), hits a request timeout (`408`), gets rate-limited (`429`), or if the API returns a transient server error (HTTP status `5xx` during control-plane reboots), the action waits 2 seconds and retries once (`login_attempts` is capped at 2, since a blocked runner IP stays blocked).
- **CLI Download Timeout:** Download of the `oc` CLI client archive from `mirror.openshift.com` is capped with a 15-second timeout and 3 retry attempts to prevent workflows from hanging indefinitely.

# Re-run jobs on blocked runners

GitHub-hosted runners share a pool of IPs, and some are blocked from the OpenShift API. oc-runner reports that as `IP blocked from OpenShift (not a code problem)`, and re-running the job usually lands on another runner. A small workflow can do that re-run for you. This repo uses one: [`.github/workflows/rerun-blocked.yml`](../.github/workflows/rerun-blocked.yml).

It runs when a listed workflow completes with a failure, reads the failed jobs' annotations, and runs `gh run rerun --failed` only when every failed job shows the blocked-runner annotation and nothing else besides the step's exit code. Any other failure leaves the run alone. `run_attempt < 3` caps it at two re-runs, so it can't loop. It needs `actions: write` (re-run) and `checks: read` (annotations), and never checks out code.

Example in `bcgov/quickstart-openshift`'s shape: its `PR`, `Merge` and `Scheduled` workflows (`pr-open.yml`, `merge.yml`, `scheduled.yml`) reach OpenShift. Quickstart doesn't call this oc-runner yet; once a repo's workflows do, save this as `.github/workflows/rerun-blocked.yml` and list the workflow names that call it:

```yaml
name: Rerun Blocked Runners

on:
  workflow_run:
    workflows: [PR, Merge, Scheduled]
    types: [completed]

permissions: {}

jobs:
  rerun:
    name: Rerun blocked jobs
    if: github.event.workflow_run.conclusion == 'failure' && github.event.workflow_run.run_attempt < 3
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    permissions:
      actions: write # gh run rerun
      checks: read # job annotations
    steps:
      - name: Re-run if only blocked-runner failures
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          RUN_ID: ${{ github.event.workflow_run.id }}
          ATTEMPT: ${{ github.event.workflow_run.run_attempt }}
        run: |
          set -euo pipefail
          jobs=$(gh api --paginate "repos/${REPO}/actions/runs/${RUN_ID}/attempts/${ATTEMPT}/jobs" \
            --jq '.jobs[] | select(.conclusion == "failure") | "\(.id)\t\(.name)"')
          [ -n "${jobs}" ] || exit 0
          while IFS=$'\t' read -r id name; do
            notes=$(gh api --paginate "repos/${REPO}/check-runs/${id}/annotations" \
              --jq '.[] | select(.annotation_level == "failure") | "\(.title // "")\t\(.message)"')
            blocked=$(grep -cE 'IP blocked from OpenShift \(not a code problem\)|is blocked from the OpenShift API' <<< "${notes}" || true)
            other=$(grep -vE 'IP blocked from OpenShift \(not a code problem\)|is blocked from the OpenShift API|^[[:space:]]*Process completed with exit code [0-9]+\.$' <<< "${notes}" | grep -c . || true)
            if [ "${blocked}" -eq 0 ] || [ "${other}" -ne 0 ]; then
              echo "::notice title=Not re-run::${name} failed for a reason other than a blocked runner IP"
              exit 0
            fi
          done <<< "${jobs}"
          gh run rerun "${RUN_ID}" --repo "${REPO}" --failed
```

`workflow_run` only fires for workflow files on the default branch, so the re-run starts working once this file is merged. The workflow names must match each workflow's `name:`.

# Troubleshooting

The `commands` block runs in strict shell mode. A command failure (including optional `grep` misses in pipelines) can stop the step immediately.

- For optional matches, use guards like `grep ... || true`
- Prefer explicit conditional checks when an empty result is valid
- `commands exceeded timeout <timeout>` means the `timeout` input stopped the `commands` block. A command inside the block that exits 124 on its own, such as one wrapped in its own `timeout`, is reported as `commands block failed with exit code 124` instead
- Set `verbose: true` to enable `set -x` tracing for the `commands` block and internal output processing; enable it temporarily and only when you are confident sensitive values will not be printed

## Safe Debugging

When `verbose: true` is enabled, shell tracing may show expanded command arguments, environment usage, and command output in logs. GitHub masks known secrets, but derived or partial secret values can still leak. Use this mode only for short-lived troubleshooting and avoid commands that print or interpolate sensitive values.

# Feedback

Please contribute your ideas!  [Issues] and [pull requests] are appreciated.

<!-- # Acknowledgements

This Action is provided courtesty of the Forestry Digital Services, part of the Government of British Columbia. -->
