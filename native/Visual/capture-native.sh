#!/bin/sh
# Renders the scenarios with the built (Debug) app: native/build/visual/native/<name>.png
# and <name>.geometry.json, the counterpart of capture-electron.mjs.
#   Visual/capture-native.sh [names…]     (from native/, after `make build`)
set -eu
cd "$(dirname "$0")/.."
APP=build/DerivedData/Build/Products/Debug/Tabs.app
DATA=$(mktemp -d)
# Dates render in UTC, as the Electron capture pins them.
trap 'rm -rf "$DATA"' EXIT
TZ=UTC TABS_DATA_DIR="$DATA" "$APP/Contents/MacOS/Tabs" --render-scenarios Visual/scenarios --out build/visual/native "$@"
