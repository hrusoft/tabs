#!/usr/bin/env bash
#
# Build both release dmgs from one commit, exactly as a release ships them:
#
#   scripts/build-dmgs.sh <ref> <outdir>
#
#   <outdir>/tabs-<version>-arm64.dmg                            the Electron app
#   <outdir>/tabs-native-experimental-<version>-universal.dmg    the native app (native/)
#
# <version> is package.json's "version" at <ref>, verbatim; both apps carry it.
# Prints the two paths on stdout; build logs go to stderr.
#
# The build runs in a `git archive` export of <ref> -- the tree the public mirror
# receives -- with its own `npm ci` and its own DerivedData, so nothing in this
# checkout (node_modules, native/build, uncommitted or ignored files such as
# native/Config/Signing.local.xcconfig) can reach a release. scripts/release.sh
# runs it before it publishes anything; run it by hand for a dry run.
#
# Needs macOS with Xcode 27, node (mise.toml) and mise (native/Makefile runs
# XcodeGen through it).
#
set -euo pipefail
shopt -s nullglob

usage="usage: build-dmgs.sh <ref> <outdir>"
ref="${1:?$usage}"
out="${2:?$usage}"
ROOT="$(git rev-parse --show-toplevel)"

note() { printf 'build-dmgs: %s\n' "$*" >&2; }

commit="$(git -C "$ROOT" rev-parse --verify "$ref^{commit}")"
src="$(mktemp -d)"
trap 'rm -rf "$src"' EXIT
git -C "$ROOT" archive "$commit" | tar -x -C "$src"
version="$(plutil -extract version raw -o - "$src/package.json")"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
electron_dmg="$out/tabs-$version-arm64.dmg"
native_dmg="$out/tabs-native-experimental-$version-universal.dmg"
rm -f "$electron_dmg" "$native_dmg"

# The export is a directory mise has never seen, so it would refuse its
# mise.toml as untrusted.
export MISE_TRUSTED_CONFIG_PATHS="$src"

note "building the Electron app $version (${commit:0:8})..."
(cd "$src" && npm ci && npm run dist:mac) >&2
# electron-builder names its dmg after the version parsed as semver, which
# strips a date's leading zeros (2026.08.23 -> 2026.8.23), so it is renamed.
built=("$src"/dist/*.dmg)
[ ${#built[@]} -eq 1 ] || { note "expected one dmg in dist/, found ${#built[@]}"; exit 1; }
mv "${built[0]}" "$electron_dmg"

note "building the native app $version..."
make -C "$src/native" bundle >&2
mv "$src/native/build/Tabs.dmg" "$native_dmg"

printf '%s\n' "$electron_dmg" "$native_dmg"
