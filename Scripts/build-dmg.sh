#!/usr/bin/env bash
#
# Build the release dmg from one commit, exactly as a release ships it:
#
#   Scripts/build-dmg.sh <ref> <outdir>
#
#   <outdir>/tabs-<version>-universal.dmg
#
# <version> is Config/Version.xcconfig's MARKETING_VERSION at <ref>, verbatim.
# Prints the dmg's path on stdout; build logs go to stderr.
#
# The build runs in a `git archive` export of <ref> -- the tree the public mirror
# receives -- with its own DerivedData, so nothing in this checkout (build/,
# uncommitted or ignored files such as Config/Signing.local.xcconfig) can reach a
# release. Scripts/release.sh runs it before it publishes anything; run it by
# hand for a dry run.
#
# Needs macOS with Xcode 27 and mise (the Makefile runs XcodeGen through it).
#
set -euo pipefail

usage="usage: build-dmg.sh <ref> <outdir>"
ref="${1:?$usage}"
out="${2:?$usage}"
ROOT="$(git rev-parse --show-toplevel)"

note() { printf 'build-dmg: %s\n' "$*" >&2; }

commit="$(git -C "$ROOT" rev-parse --verify "$ref^{commit}")"
src="$(mktemp -d)"
trap 'rm -rf "$src"' EXIT
git -C "$ROOT" archive "$commit" | tar -x -C "$src"
version="$(sed -n 's/^MARKETING_VERSION = //p' "$src/Config/Version.xcconfig")"
[ -n "$version" ] || { note "no MARKETING_VERSION in Config/Version.xcconfig"; exit 1; }

mkdir -p "$out"
out="$(cd "$out" && pwd)"
dmg="$out/tabs-$version-universal.dmg"
rm -f "$dmg"

note "building Tabs $version (${commit:0:8})..."
make -C "$src" bundle >&2
mv "$src/build/Tabs.dmg" "$dmg"

printf '%s\n' "$dmg"
