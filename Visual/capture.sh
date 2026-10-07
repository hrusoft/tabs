#!/bin/sh
# Renders the scenarios — core's (Visual/scenarios) and every plugin's
# (Plugins/<Name>/Visual/scenarios) — with the built (Debug) app:
# <dir>/<name>.png and <dir>/<name>.geometry.json.
#   Visual/capture.sh <dir> [names…]     (after `make build`; the Makefile's visual targets run it)
set -eu
cd "$(dirname "$0")/.."
OUT="${1:?usage: Visual/capture.sh <dir> [names…]}"
shift
APP=build/DerivedData/Build/Products/Debug/Tabs.app
DATA=$(mktemp -d)
trap 'rm -rf "$DATA"' EXIT
SCENARIOS=""
for dir in Visual/scenarios Plugins/*/Visual/scenarios; do
  [ -d "$dir" ] && SCENARIOS="$SCENARIOS --render-scenarios $dir"
done
# Dates render in UTC, so a capture doesn't depend on the machine's zone.
# shellcheck disable=SC2086 # one word per directory
TZ=UTC TABS_DATA_DIR="$DATA" "$APP/Contents/MacOS/Tabs" $SCENARIOS --out "$OUT" "$@"
