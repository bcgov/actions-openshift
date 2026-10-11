#!/usr/bin/env python3
"""ShellCheck the bash run: blocks in composite action.yml files.

actionlint only checks run: blocks in workflow files, so composite actions are
linted here. Each bash step is written to a temporary file, with any expression
replaced by a placeholder, and passed to shellcheck. crunchy/ is skipped.

Usage: python3 scripts/shellcheck_composite_actions.py [shellcheck args...]
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

SKIP = {"crunchy"}
EXPR = re.compile(r"\$\{\{.*?\}\}")


def main() -> int:
    extra = sys.argv[1:] or ["--severity=warning"]
    failed = 0
    checked = 0
    with tempfile.TemporaryDirectory() as tmp:
        for action in sorted(Path(".").glob("*/action.yml")):
            if action.parent.name in SKIP:
                continue
            steps = (yaml.safe_load(action.read_text()) or {}).get("runs", {}).get("steps", [])
            for i, step in enumerate(steps):
                if "run" not in step or step.get("shell") != "bash":
                    continue
                name = step.get("name") or step.get("id") or f"step {i + 1}"
                script = EXPR.sub("__GHA_EXPR__", step["run"])
                path = Path(tmp) / f"{action.parent.name}-{i + 1}.sh"
                # GitHub runs shell: bash as bash --noprofile --norc -eo pipefail
                path.write_text("#!/usr/bin/env bash\nset -eo pipefail\n" + script)
                checked += 1
                result = subprocess.run(
                    ["shellcheck", *extra, str(path)], capture_output=True, text=True
                )
                if result.returncode != 0:
                    failed += 1
                    print(f"::group::{action} step '{name}' (line numbers are +2 from the run: block)")
                    print(result.stdout.replace(str(path), f"{action} [{name}]"))
                    print("::endgroup::")
                    print(f"::error file={action}::ShellCheck findings in step '{name}'")

    if failed:
        print(f"\n{failed} of {checked} composite action bash step(s) have ShellCheck findings.")
        return 1
    print(f"ShellCheck passed for {checked} composite action bash step(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
