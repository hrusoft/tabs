#!/bin/bash
# Xcode build phase (every shipped image): writes Resources/TabsBuildStamp.plist
#
#   role              sdk | core | app | plugin   (TABS_IMAGE_ROLE)
#   configuration     $CONFIGURATION
#   fingerprint       Scripts/shared-fingerprint.sh $CONFIGURATION, computed once
#                     per build by the SharedFingerprint target
#   bundledPlugins    app only: the values of every TABS_BUNDLED_PLUGIN_<ID>
#                     setting (one per plugin, from its plugin.yml)
#
# A file of our own rather than keys in Info.plist: Xcode regenerates the
# product's Info.plist on its own schedule, which can land after a script
# phase and silently erase what it wrote. This file is the phase's declared
# output, so signing (which seals it) always comes after.
#
# At launch core compares every stamp with the loaded SDK's before running any
# plugin code; Scripts/verify-app.sh checks them all again after packaging.
# The file is replaced only when its content changes, so an unchanged image
# isn't re-signed every build.
set -euo pipefail

role="${TABS_IMAGE_ROLE:?set TABS_IMAGE_ROLE on the target}"
computed="${OBJROOT}/TabsSharedFingerprint-${CONFIGURATION}.txt"
if [ -s "$computed" ]; then
  fingerprint="$(cat "$computed")"
else
  fingerprint="$("${SRCROOT}/Scripts/shared-fingerprint.sh" "${CONFIGURATION}")"
fi
destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/TabsBuildStamp.plist"

bundled=""
if [ "$role" = app ]; then
  bundled="	<key>bundledPlugins</key>
	<array>
$(env | sed -n 's/^TABS_BUNDLED_PLUGIN_[A-Z0-9_]*=//p' | LC_ALL=C sort -u | while read -r id; do printf '\t\t<string>%s</string>\n' "$id"; done)
	</array>
"
fi

new="$(mktemp)"
cat > "$new" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
${bundled}	<key>configuration</key>
	<string>${CONFIGURATION}</string>
	<key>fingerprint</key>
	<string>${fingerprint}</string>
	<key>role</key>
	<string>${role}</string>
</dict>
</plist>
PLIST
plutil -lint -s "$new"
# mktemp makes the file 0600, and the app's own Resources are never copied
# (which would reset the mode): an install owned by another user couldn't read
# it, and core would refuse every plugin.
chmod 644 "$new"
mkdir -p "$(dirname "$destination")"
if cmp -s "$new" "$destination"; then rm "$new"; else mv "$new" "$destination"; fi
chmod 644 "$destination"
