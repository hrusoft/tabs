#!/bin/bash
# Packs a built Tabs.app into a dmg that opens as an install window: the app, a
# link to /Applications to drag it onto, and a Read Me (Scripts/dmg/read-me.txt:
# how to clear the quarantine flag on an app without a Developer ID signature),
# over a background that says so (Artwork/dmg-background.svg), with the app's
# icon as the volume's.
#
#   Scripts/make-dmg.sh path/to/Tabs.app path/to/out.dmg     (`make bundle` does)
#
# Prints the dmg's absolute path.
#
# The window is Finder's view settings, stored on the volume: a .DS_Store (icon
# view, window size, where each item sits, which background), the background
# (.background.tiff: Scripts/dmg/background.png and its @2x as one Retina image)
# and .VolumeIcon.icns. dmgbuild writes them directly (Scripts/dmg/settings.py),
# so this runs unattended: no Finder scripting, no Automation permission. mise
# runs a pinned dmgbuild through uv (DMGBUILD overrides it); the first run
# downloads it, later ones run from uv's cache, offline.
#
# It packs the app as built, so run the packaging gate on it first (`make bundle`
# does). Then it opens what it made and checks it: the app's signature still
# verifies, and every piece of the window is there.
set -euo pipefail

usage="usage: make-dmg.sh path/to/Tabs.app path/to/out.dmg"
app="${1:?$usage}"
dmg="${2:?$usage}"
root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
read -r -a dmgbuild <<<"${DMGBUILD:-mise exec uv@0.12.16 -- uvx --python 3.13 --with ds-store==1.3.3 --with mac-alias==2.2.3 dmgbuild@1.6.7}"

fail() { printf 'make-dmg: %s\n' "$*" >&2; exit 1; }

mkdir -p "$(dirname "$dmg")"
# Resolved (-P) as dmgbuild resolves it: it works on a .temp*.dmg beside it.
dmg="$(cd "$(dirname "$dmg")" && pwd -P)/$(basename "$dmg")"
rm -f "$dmg"

work="$(mktemp -d)"
mount="$work/mount"
attached=
# The devices of dmgbuild's working images still attached. One stopped before it
# could detach (Ctrl-C) would stay attached, hidden from Finder, until a restart.
leftovers() {
  hdiutil info 2>/dev/null | awk -v temp="$(dirname "$dmg")/.temp" '
    /^image-path/ { sub(/^image-path[ \t]*:[ \t]*/, ""); hit = index($0, temp) == 1; next }
    hit && /^\/dev\/disk[0-9]+[ \t]/ { print $1; hit = 0 }'
}
cleanup() {
  [ -z "$attached" ] || diskutil quiet eject "$mount" || true
  for device in $(leftovers); do diskutil quiet eject "$device" || true; done
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The volume's icon: the app's icon set at every size (the icns the asset
# catalog leaves in the app stops at 256 px).
mkdir "$work/AppIcon.iconset"
cp "$root"/Sources/Tabs/Assets.xcassets/AppIcon.appiconset/icon_*.png "$work/AppIcon.iconset/"
iconutil -c icns "$work/AppIcon.iconset" -o "$work/VolumeIcon.icns"

# Once its index cache is stale, uv asks PyPI about the pins on every run. With
# all of them cached it needn't, and then it needs no network.
if UV_OFFLINE=1 "${dmgbuild[@]}" --help >/dev/null 2>&1; then export UV_OFFLINE=1; fi
# Quiet when it works; uv's and mise's notes are shown only when it fails.
if ! output="$("${dmgbuild[@]}" -s "$root/Scripts/dmg/settings.py" \
  -D app="$app" -D readme="$root/Scripts/dmg/read-me.txt" \
  -D icon="$work/VolumeIcon.icns" -D background="$root/Scripts/dmg/background.png" \
  "Tabs $version" "$dmg" 2>&1)"; then
  printf '%s\n' "$output" >&2
  exit 1
fi
# dmgbuild drives hdiutil, and macOS 27 marks some of its commands deprecated
# (for `diskutil image`). They still work, but a macOS without them would break
# this script, so every run says which ones it used.
deprecated="$(sed -n "s/^hdiutil: WARNING: 'hdiutil \([a-z]*\) .*deprecated.*/\1/p" <<<"$output" | sort -u | paste -sd ' ' -)"
[ -z "$deprecated" ] \
  || printf 'make-dmg: dmgbuild used deprecated hdiutil commands (%s); see docs/ARCHITECTURE.md, Version and release\n' "$deprecated" >&2

# What Finder needs for the window, and an app that still opens: dmgbuild copies
# it with ditto (the copy stays sealed) but doesn't check that the copy worked.
diskutil image attach --readOnly --nobrowse --mountPoint "$mount" "$dmg" >/dev/null
attached=1
signature="$(codesign --verify --deep --strict "$mount/Tabs.app" 2>&1)" \
  || fail "Tabs.app's signature doesn't verify in the dmg: $signature"
[ "$(readlink "$mount/Applications")" = /Applications ] || fail "no Applications link"
cmp -s "$root/Scripts/dmg/read-me.txt" "$mount/Read Me.txt" || fail "no Read Me.txt"
[ -s "$mount/.DS_Store" ] || fail "no .DS_Store: Finder would open a plain window"
[ "$(tiffutil -info "$mount/.background.tiff" 2>/dev/null | grep -c '^Directory')" = 2 ] \
  || fail "the background isn't one 1x and one 2x image"
cmp -s "$work/VolumeIcon.icns" "$mount/.VolumeIcon.icns" || fail "no volume icon"
[ "$(GetFileInfo -aC "$mount")" = 1 ] || fail "the volume's custom icon flag isn't set"
diskutil quiet eject "$mount"
attached=

echo "$dmg"
