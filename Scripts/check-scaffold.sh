#!/bin/bash
# Proves Scripts/new-plugin.py's output works as generated: scaffolds a blank
# plugin and a content-type one into a copy of the tree, then lints, builds,
# gates (Scripts/verify-app.sh: bundled, linked, stamped, active in the running
# app) and tests them there. Part of `make check`.
#
# A copy, so the working tree never holds the samples: build/scaffold-check
# mirrors the repository and keeps its own DerivedData, so later runs are
# incremental. The samples are regenerated every run, so their warnings always
# show. The copy holds no other plugin: the samples need nothing but core, so
# the copy builds neither the shipped plugins nor their tests again (and core
# builds, gates and starts with no plugin of its own).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
work="$here/build/scaffold-check"
copy="$work/tree"
config="${CONFIG:-Debug}"

fail() { echo "check-scaffold: $*" >&2; exit 1; }

mkdir -p "$copy"
shipped=()
for dir in "$here"/Plugins/*/; do shipped+=(--exclude "/Plugins/$(basename "$dir")/"); done
# Excluded paths survive --delete: the copy's own build products and project.
rsync -a --delete --exclude /build/ --exclude /Tabs.xcodeproj/ --exclude /.git --exclude /.claude/ ${shipped[@]+"${shipped[@]}"} \
    "$here/" "$copy/"
# The shipped plugins: an older copy's folders, and their bundles in its app
# (a build never takes a bundle back out; the gate would see them).
for dir in "$here"/Plugins/*/; do rm -rf "$copy/Plugins/$(basename "$dir")"; done
rm -rf "$copy/build/DerivedData/Build/Products/$config/Tabs.app/Contents/PlugIns"

samples=(ScaffoldBlank ScaffoldPane)
(cd "$copy" && Scripts/new-plugin.py scaffold-blank && Scripts/new-plugin.py scaffold-pane --content-type) >/dev/null

# Blank and standalone: the SDK (and, in tests, the harness) is all it reaches.
existing=()
for dir in "$here"/Plugins/*/; do
    name="$(basename "$dir")"
    id="$(plutil -extract TabsPlugin.id raw -o - "$dir/Info.plist")"
    existing+=("$name" "$id")
done
for sample in "${samples[@]}"; do
    folder="$copy/Plugins/$sample"
    for word in "${existing[@]}"; do
        if grep -rqiF -- "$word" "$folder"; then fail "Plugins/$sample names the existing plugin \"$word\""; fi
    done
    if grep -rqE 'TabsCore|@testable' "$folder"; then fail "Plugins/$sample reaches core directly"; fi
    imports="$(cat "$folder"/Sources/*.swift | sed -n 's/^import //p' | sort -u | tr '\n' ' ')"
    [ "$imports" = "AppKit TabsPluginSDK " ] || fail "Plugins/$sample's sources import: $imports"
    imports="$(cat "$folder"/Tests/*.swift | sed -n 's/^import //p' | sort -u | tr '\n' ' ')"
    [ "$imports" = "TabsPluginSDK Testing " ] || fail "Plugins/$sample's tests import: $imports"
done

log="$work/check.log"
tests="${samples[*]/%/PluginTests}"
if ! make -C "$copy" CONFIG="$config" lint verify test-plugins ONLY="$tests" >"$log" 2>&1; then
    cat "$log"
    fail "the scaffolded plugins don't pass in a copy of the tree ($log)"
fi
warnings=$(grep -E '^[^[:space:]].*/Plugins/Scaffold[A-Za-z]*/.*warning: ' "$log" | sort -u || true)
[ -z "$warnings" ] || { printf '%s\n' "$warnings"; fail "the scaffolded plugins build with warnings"; }
grep -q '^ok:   --plugin-report: every plugin active' "$log" || fail "the gate didn't report the plugins active ($log)"
echo "check-scaffold: a blank plugin and a content-type plugin, as scaffolded, lint, build, pass the gate and their tests"
