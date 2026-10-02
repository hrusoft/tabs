#!/bin/bash
# Fails if building every target, tests included, prints a compiler or linker
# warning. Part of `make check`.
#
# A clean build of its own, because an incremental build reports warnings only
# for the files it recompiles: a warning in a file that didn't change never
# shows again. And the build settings can't do this alone: Swift 6.4's
# -warnings-as-errors (SWIFT_TREAT_WARNINGS_AS_ERRORS, on project-wide) doesn't
# escalate AppKit's main-actor isolation warnings, so they build green.
set -euo pipefail
cd "$(dirname "$0")/.."

config="${CONFIG:-Debug}"
derived=build/DerivedData-warnings
log=build/warnings.log

rm -rf "$derived"
if ! xcodebuild -project Tabs.xcodeproj -scheme Tabs -configuration "$config" -derivedDataPath "$derived" \
    -destination 'platform=macOS' -skipPackagePluginValidation -quiet build-for-testing >"$log" 2>&1; then
    cat "$log"
    echo "check-warnings: the build failed"
    exit 1
fi
rm -rf "$derived"

# One line per warning: the diagnostic itself (a path, or `ld:`), not the
# indented source excerpt the compiler prints under it.
warnings=$(grep -E '^[^[:space:]].*warning: ' "$log" | sort -u || true)
if [ -n "$warnings" ]; then
    printf '%s\n' "$warnings"
    echo "check-warnings: $(printf '%s\n' "$warnings" | wc -l | tr -d ' ') warning(s) in a clean build; the full log is $log"
    exit 1
fi
echo "check-warnings: a clean build of every target has no warnings"
