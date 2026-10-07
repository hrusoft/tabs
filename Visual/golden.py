#!/usr/bin/env python3
"""Copies a capture's geometry dumps into the goldens: each beside its scenario,
`Visual/golden` for core's (`Visual/scenarios`) and `Plugins/<Name>/Visual/golden`
for a plugin's. Two-space indents, each rect (and every other list of numbers)
on one line.

    Visual/golden.py <capture dir>     (`make visual-golden` runs it)
"""

import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NUMBERS = re.compile(r"\[\s*(-?[0-9.eE+-]+(?:,\s*-?[0-9.eE+-]+)*)\s*\]")


def golden_dirs():
    """Each scenario's golden directory, by scenario name."""
    dirs = {}
    for scenarios in [os.path.join(ROOT, "Visual", "scenarios")] + sorted(glob.glob(os.path.join(ROOT, "Plugins", "*", "Visual", "scenarios"))):
        for path in glob.glob(os.path.join(scenarios, "*.json")):
            dirs[os.path.basename(path)[: -len(".json")]] = os.path.join(os.path.dirname(scenarios), "golden")
    return dirs


def main(argv):
    if len(argv) != 1:
        sys.exit(__doc__)
    dumps = sorted(glob.glob(os.path.join(argv[0], "*.geometry.json")))
    if not dumps:
        sys.exit(f"golden.py: no geometry dumps in {argv[0]}")
    dirs = golden_dirs()
    for path in dumps:
        name = os.path.basename(path)[: -len(".geometry.json")]
        if name not in dirs:
            sys.exit(f"golden.py: {name} is no scenario's")
        with open(path) as f:
            text = json.dumps(json.load(f), indent=2, ensure_ascii=False)
        text = NUMBERS.sub(lambda m: "[" + ", ".join(re.split(r",\s*", m.group(1))) + "]", text)
        os.makedirs(dirs[name], exist_ok=True)
        with open(os.path.join(dirs[name], f"{name}.geometry.json"), "w") as f:
            f.write(text + "\n")
    print(f"golden.py: {len(dumps)} golden(s) written")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
