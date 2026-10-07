#!/usr/bin/env python3
"""Test file lint: every test keeps its files under TestTemporary.

A test process's folders and files go in its own `tabs-tests.noindex/<pid>`
(Tests/Process/TestTemporary.swift), removed as it exits. One made straight in
the temporary directory outlives the run: a full run makes about a thousand,
and they piled up in the hundred thousands, each one indexed by Spotlight. This
lint refuses reaching the temporary directory any other way in test sources
(Tests/, Plugins/<Name>/Tests). A line that must is marked, with a reason:
    let x = NSTemporaryDirectory()  // test-files: allow — what the product reads

Usage: Scripts/lint-test-files.py [root]   (default: the repository)
"""

import pathlib
import re
import sys

RULE = re.compile(
    r"FileManager\.default\.temporaryDirectory|\bNSTemporaryDirectory\s*\(|\bmkdtemp\s*\(|\bmkstemp\s*\(|"
    r"\.itemReplacementDirectory\b"
)
HOME = pathlib.Path("Tests/Process/TestTemporary.swift")


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent)
    sources = list((root / "Tests").rglob("*.swift")) + list(root.glob("Plugins/*/Tests/**/*.swift"))
    problems = []
    for path in sorted(sources):
        relative = path.relative_to(root)
        if relative == HOME:
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            code = line.split("//", 1)[0] if "test-files: allow" not in line else ""
            if RULE.search(code):
                problems.append(f"{relative}:{number}: a test's files go under TestTemporary ({HOME}): {line.strip()}")
    for problem in problems:
        print(problem)
    if problems:
        print(f"lint-test-files: {len(problems)} problem(s)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
