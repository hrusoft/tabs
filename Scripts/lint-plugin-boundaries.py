#!/usr/bin/env python3
"""Plugin boundary lint: what the compiler and the packaging gate can't see.

Plugins are isolated from each other by the SDK: they reach only what core
exposes. In-process code can still go around it through process-wide state
every plugin shares. This lint refuses those APIs in plugin sources
(Plugins/<Name>/Sources, Tests/Fixtures), each with the SDK way to do the
same, and checks that no plugin target overrides its template (its own
SWIFT_PACKAGE_NAME is what keeps core's `package` API out of reach).

Comments and string contents don't count; interpolations do. Every Plugin
target's sources (<pluginDir>/Sources, from project.yml and each plugin.yml)
are scanned; a plugin's own tests aren't.

A reviewed exception goes on the line itself, with a reason:
    let x = UserDefaults(suiteName: "…")  // boundary: allow — migrating the old app's data

Usage: Scripts/lint-plugin-boundaries.py [root]   (default: the repository)
"""

import pathlib
import re
import sys

ATTRIBUTES = r"(?:@\w+(?:\([^)]*\))?\s+)*"
MODIFIERS = r"(?:(?:public|private|fileprivate|internal|package|nonisolated\(unsafe\))\s+)*"
RULES = [
    (r"\bimport\s+TabsCore\b", "core is private: plugins see it only through TabsPluginSDK"),
    (r"@testable\s+import\b", "@testable reaches another module's internals"),
    (r"\bUserDefaults\b|@AppStorage\b|@SceneStorage\b", "one defaults domain is shared by every plugin: use context.settings"),
    (
        r"\b(Distributed)?NotificationCenter\.default\b",
        "posting reaches other plugins, and observing with object: nil sees their views: "
        + "use core's events, delegates or your own objects (or mark a reviewed use)",
    ),
    (
        r"\bNSApp(lication\.shared)?[!?]?\.(windows|orderedWindows|keyWindow|mainWindow|mainMenu|appearance|delegate)\b",
        "core's app state and other plugins' views: reach only your own views (the theme is context.theme)",
    ),
    (
        r"\.superview[!?]?\.(superview|subviews)\b|\bwindow[!?]?\.contentView\b|\bcontentViewController\b",
        "walks into views that aren't yours (a window's tabs are siblings): reach only your own views",
    ),
    (r"\bNSEvent\.add(Local|Global)MonitorForEvents\b", "sees every key typed in every pane, passwords included"),
    (
        r"\.runModal\s*\(|\bbeginSheetModal\b|\bNSAlert\b|\bNSOpenPanel\b|\bNSSavePanel\b",
        "a modal blocks the whole app (and hangs it under tests, where nobody answers): "
        + "ask through the pane context: confirm, choose and alert for questions, chooseDirectory and chooseFile for the open panel",
    ),
    (
        r"(?<!func )(?<![\w.])(?:(?:Darwin|Foundation)\.)?(?:(chdir|setenv|putenv|unsetenv|umask)\s*\(|(signal|sigaction)\s*\(\s*SIG)",
        "process-wide state every plugin shares: pass the directory and pane.childEnvironment to what you spawn",
    ),
    (r"\bchangeCurrentDirectoryPath\b", "the process's directory is every plugin's: pass it to what you spawn"),
    (
        r"\bWKWebsiteDataStore\.default\s*\(",
        "shared with every plugin's web views: WKWebsiteDataStore(forIdentifier: context.webDataStoreIdentifier)",
    ),
    (r"\b(HTTPCookieStorage|URLCache|URLCredentialStorage|URLSession)\.shared\b", "shared with every plugin: use your own configuration"),
    (r"\bNSClassFromString\b", "reaches other plugins' classes by name"),
    (r"\bMirror\s*\(\s*reflecting\b", "reflection walks into core's objects"),
    (r"\bBundle\.main\b", "the app's bundle: your resources are in context.bundle"),
    (r"\bNSTemporaryDirectory\s*\(|\bFileManager\.default\.temporaryDirectory\b", "shared scratch space: use context.temporaryDirectory"),
    (
        r"\bFileManager\.default\.urls\s*\(\s*for:",
        "shared app directories: use context.dataDirectory, cacheDirectory or temporaryDirectory",
    ),
    (
        r"^\s*" + ATTRIBUTES + MODIFIERS + r"static\s+var\s+\w+\s*(:[^={]*)?=",
        "state shared by every instance: core may make several, so keep state on the instance",
    ),
    (r"\bstatic\s+let\s+shared\b", "a shared instance is state every instance of the plugin shares: keep it on the instance"),
    (r"^" + ATTRIBUTES + MODIFIERS + r"var\s", "a global is shared by every instance: keep state on the instance"),
]
ALLOW = re.compile(r"//\s*boundary:\s*allow\b\s*\S")
STRING_START = re.compile(r'(#*)("""|")')


def blank_non_code(text):
    """The source with comments and string contents blanked (same length,
    same line breaks). Interpolations inside strings are code, and nested
    block comments, multi-line and raw strings are understood."""
    out, i, n = [], 0, len(text)
    modes = [("code", 0)]  # ("code", open parens) or ("string", multiline, hashes)

    def blank(fragment):
        out.append("".join("\n" if ch == "\n" else " " for ch in fragment))

    while i < n:
        mode = modes[-1]
        if mode[0] == "code":
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = n if end < 0 else end
                blank(text[i:end])
                i = end
                continue
            if text.startswith("/*", i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if text.startswith("/*", j):
                        depth, j = depth + 1, j + 2
                    elif text.startswith("*/", j):
                        depth, j = depth - 1, j + 2
                    else:
                        j += 1
                blank(text[i:j])
                i = j
                continue
            start = STRING_START.match(text, i)
            if start:
                out.append(start.group(0))
                i = start.end()
                modes.append(("string", start.group(2) == '"""', len(start.group(1))))
                continue
            ch = text[i]
            if ch == "(":
                modes[-1] = ("code", mode[1] + 1)
            elif ch == ")":
                if mode[1] == 0 and len(modes) > 1:
                    modes.pop()  # the end of an interpolation: back in the string
                    out.append(ch)
                    i += 1
                    continue
                modes[-1] = ("code", mode[1] - 1)
            out.append(ch)
            i += 1
            continue
        _, multiline, hashes = mode
        close = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        if text.startswith(close, i):
            out.append(close)
            i += len(close)
            modes.pop()
        elif text.startswith(escape + "(", i):
            out.append(escape + "(")
            i += len(escape) + 1
            modes.append(("code", 0))
        elif text.startswith(escape, i):
            blank(text[i : i + len(escape) + 1])
            i += len(escape) + 1
        else:
            blank(text[i])
            i += 1
    return "".join(out)


def spec_files(root):
    """project.yml and every plugin's plugin.yml."""
    return [root / "project.yml"] + sorted(root.glob("Plugins/*/plugin.yml"))


def plugin_source_dirs(root):
    """Every Plugin target's sources: <pluginDir>/Sources, from the specs."""
    dirs = set()
    for spec in spec_files(root):
        for match in re.finditer(r"pluginDir:\s*([\w./-]+)", spec.read_text()):
            dirs.add(match.group(1).rstrip(",") + "/Sources")
    return sorted(dirs)


def lint_sources(root):
    problems, seen = [], set()
    for directory in plugin_source_dirs(root):
        for path in sorted((root / directory).rglob("*.swift")):
            if path in seen:
                continue
            seen.add(path)
            text = path.read_text()
            for number, (line, code) in enumerate(zip(text.splitlines(), blank_non_code(text).splitlines()), 1):
                if ALLOW.search(line):
                    continue
                for pattern, why in RULES:
                    if re.search(pattern, code):
                        problems.append(f"{path.relative_to(root)}:{number}: {why}\n    {line.strip()}")
    return problems


# A plugin's bundle and its unit, UI and end-to-end test targets.
PLUGIN_TEMPLATES = {"Plugin", "PluginTests", "PluginUITests", "PluginE2ETests"}
TEST_TEMPLATES = PLUGIN_TEMPLATES - {"Plugin"}


def lint_project(root):
    """Plugin targets (and their test targets) take everything from their
    template, except SwiftPM packages: a plugin may link third-party packages
    of its own (statically, SwiftPM's default), so its targets may list
    `dependencies:` made only of `- package: <Name>` entries. And a test target
    may say how many of its tests run at once, nothing else in `settings`:
    `base:` with `TEST_PARALLELIZATION_WIDTH: <n>` (Tests/Process)."""
    problems = []
    for spec in spec_files(root):
        targets, target, key, in_targets = {}, None, None, False
        for line in spec.read_text().splitlines():
            if re.match(r"^\S", line):
                in_targets, target = line.startswith("targets:"), None
                continue
            if not in_targets:
                continue
            top = re.match(r"^  (\w[\w-]*):\s*$", line)
            if top:
                target = top.group(1)
                targets[target] = {"keys": [], "templates": [], "foreign": [], "settings": []}
                continue
            if target is None:
                continue
            entry = re.match(r"^    (\w+):\s*(.*)$", line)
            if entry:
                key = entry.group(1)
                targets[target]["keys"].append(key)
                if key == "templates":
                    targets[target]["templates"] += re.findall(r"\w+", entry.group(2))
                elif key == "dependencies" and entry.group(2).strip():
                    # Only a block list of `- package:` lines is checkable; an
                    # inline value (`[{ target: TabsCore }]`) is refused whole.
                    targets[target]["foreign"].append(line.strip())
                elif key == "settings" and entry.group(2).strip():
                    targets[target]["settings"].append(line.strip())
                continue
            if key == "settings":
                stripped = line.strip()
                if stripped and not stripped.startswith("#") and not re.match(r"^      base:\s*$", line) \
                        and not re.match(r"^        TEST_PARALLELIZATION_WIDTH:\s*\d+\s*$", line):
                    targets[target]["settings"].append(stripped)
                continue
            item = re.match(r"^\s+-\s*(\w+)\s*$", line)
            if item and key == "templates":
                targets[target]["templates"].append(item.group(1))
            elif key == "dependencies" and line.strip() and not re.match(r"^\s+-\s*package:\s*[\w.-]+\s*$", line):
                targets[target]["foreign"].append(line.strip())
        for name, info in targets.items():
            allowed = ["templates", "templateAttributes", "dependencies"]
            if TEST_TEMPLATES & set(info["templates"]) and not info["settings"]:
                allowed.append("settings")
            extra = [k for k in info["keys"] if k not in allowed]
            if info["foreign"]:
                extra.append("dependencies other than packages (" + "; ".join(info["foreign"]) + ")")
            if PLUGIN_TEMPLATES & set(info["templates"]) and extra:
                problems.append(
                    f"{spec.relative_to(root)}: plugin target {name} sets {', '.join(extra)}; "
                    + "plugin targets take everything from their template"
                )
    return problems


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent)
    problems = lint_sources(root) + lint_project(root)
    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} plugin boundary problem(s). See Scripts/lint-plugin-boundaries.py and docs/PLUGINS.md.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
