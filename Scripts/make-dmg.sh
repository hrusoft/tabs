#!/bin/bash
# Packs a built Tabs.app into a dmg: the app, a link to /Applications to drag it
# onto, and a Read Me (Scripts/dmg-read-me.txt: how to clear the quarantine flag
# on an app without a Developer ID signature).
#
#   Scripts/make-dmg.sh path/to/Tabs.app path/to/out.dmg     (`make bundle` does)
#
# A plain image: no background or icon layout. It packs the app as built, so run
# the packaging gate on it first (`make bundle` does).
set -euo pipefail

app="${1:?usage: make-dmg.sh path/to/Tabs.app path/to/out.dmg}"
dmg="${2:?usage: make-dmg.sh path/to/Tabs.app path/to/out.dmg}"
readme="$(cd "$(dirname "$0")" && pwd)/dmg-read-me.txt"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
# ditto keeps the frameworks' symlinks, modes and extended attributes, so the
# copy is still sealed by the signature the gate verified.
ditto "$app" "$stage/Tabs.app"
ln -s /Applications "$stage/Applications"
cp "$readme" "$stage/Read Me.txt"

mkdir -p "$(dirname "$dmg")"
rm -f "$dmg"
diskutil image create from --format ULFO --volumeName "Tabs $version" "$stage" "$dmg" >/dev/null
echo "$dmg"
