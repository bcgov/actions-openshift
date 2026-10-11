# scripts

`audit_composite_actions.py` and `shellcheck_composite_actions.py` are run by this repository's CI. The second extracts each bash `run:` block from the composite `action.yml` files (except `crunchy/`) and runs ShellCheck on it, since actionlint only covers workflow files.

Workstation scripts that used to live here (`cert/`, `oc/`) moved to [bcgov/devops-scripts](https://github.com/bcgov/devops-scripts).
