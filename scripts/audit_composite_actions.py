#!/usr/bin/env python3
"""Audit composite actions for direct context interpolation in script blocks."""

import re
import sys
from pathlib import Path


def main() -> int:
    errors = 0
    ctx = "${" + "{"
    pattern = re.compile(r"\$\{\{\s*(?:github|inputs)\.")

    for action_path in sorted(Path(".").glob("*/action.yml")):
        with open(action_path, "r", encoding="utf-8") as f:
            in_script = False
            script_indent = 0
            for line_num, line in enumerate(f, start=1):
                stripped = line.strip()
                indent = len(line) - len(line.lstrip())
                match = re.search(r"^\s*(?:-\s+)?(run|commands):\s*(.*)", line)
                if match:
                    in_script = True
                    script_indent = indent
                    rest = match.group(2)
                    if rest and not rest.startswith("|") and not rest.startswith(">"):
                        if pattern.search(rest):
                            print(
                                f"::error file={action_path},line={line_num}::"
                                f"Direct {ctx} github.* }} or {ctx} inputs.* }} interpolation in {match.group(1)}: {stripped}"
                            )
                            errors += 1
                        in_script = False
                    continue

                if in_script:
                    if stripped and indent <= script_indent and not stripped.startswith("#"):
                        in_script = False
                    else:
                        if pattern.search(line):
                            print(
                                f"::error file={action_path},line={line_num}::"
                                f"Direct {ctx} github.* }} or {ctx} inputs.* }} interpolation in script block: {stripped}"
                            )
                            errors += 1

    if errors:
        print(f"\nFound {errors} direct interpolation(s) in composite action script blocks.")
        return 1

    print(
        f"Composite actions audit passed: zero direct {ctx} github.* }} or {ctx} inputs.* }} interpolations in script blocks."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
