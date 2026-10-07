#!/bin/bash
# Packaging gate for a built Tabs.app: checks what neither the compiler nor the
# tests can see, because it is about how the images were assembled.
#
#   1. Exactly one SDK image, and no other image defines the SDK's symbols (a
#      statically linked copy makes every plugin's `as? TabsPlugin` fail).
#   2. Roles: every framework is stamped sdk or core; every plugin is a stamped
#      MH_BUNDLE.
#   3. Linkage: every image binds the SDK by @rpath; plugins link only system
#      libraries and the SDK — never core, never anything else. Plugins are
#      isolated from each other and see only what core exposes.
#   4. Fingerprints: every image carries the same stamp, and it is what the
#      sources and build configuration on disk produce for this configuration.
#   5. Bundled plugins: the app's stamped list and Contents/PlugIns agree exactly,
#      and each manifest id matches its bundle name.
#   6. Every file is readable by other users (an install owned by root).
#   7. The signature seals the whole bundle.
#   8. The app itself, headless: build integrity holds, every plugin activates,
#      and the Objective-C runtime reports no duplicate classes.
#   9. The app itself, launched: it comes up (hidden, on scratch data), answers
#      on its control socket with every plugin active, and quits on SIGTERM —
#      the GUI launch path, in whatever configuration was built (Release too).
#  10. The bundled skill: Contents/Resources/skills/tabs holds SKILL.md and an executable
#      scripts/tabs-ctl, and is byte-identical to Sources/Tabs/Resources/skills/tabs.
#  11. The relay: Contents/Helpers/tabs-ctl is a Mach-O executable for the app's
#      architectures that links only system libraries, and the skill's scripts/tabs-ctl
#      reaches it.
#  12. Versions: the app, every framework, every plugin and the relay carry
#      Config/Version.xcconfig's MARKETING_VERSION, verbatim, as CFBundleShortVersionString
#      and CFBundleVersion.
#
# Usage: Scripts/verify-app.sh path/to/Tabs.app
set -uo pipefail
# A pipe into `grep -q` fails under pipefail when grep, done at its first match, closes it while the
# writer is still writing (SIGPIPE): a check that wrongly fails under load. Checks read here-strings.

app="$(cd "${1:?usage: verify-app.sh path/to/Tabs.app}" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }
rel() { echo "${1#"$app"/Contents/}"; }

sdk_install_name="@rpath/TabsPluginSDK.framework/Versions/A/TabsPluginSDK"
sdk_binary="$app/Contents/Frameworks/TabsPluginSDK.framework/Versions/A/TabsPluginSDK"

# Mach-O images, NUL-safe.
images=()
while IFS= read -r -d '' file; do
  grep -q 'Mach-O' <<< "$(file -b "$file")" && images+=("$file")
done < <(find "$app/Contents" -type f -perm -u+x -print0)
plugins=()
while IFS= read -r -d '' dir; do plugins+=("$dir"); done \
  < <(find "$app/Contents/PlugIns" -mindepth 1 -maxdepth 1 -name '*.tabsplugin' -print0 | sort -z)
frameworks=()
while IFS= read -r -d '' dir; do frameworks+=("$dir"); done \
  < <(find "$app/Contents/Frameworks" -mindepth 1 -maxdepth 1 -name '*.framework' -print0 | sort -z)
executable_of() { echo "$1/Contents/MacOS/$(plist "$1/Contents/Info.plist" CFBundleExecutable)"; }
stamp_of_framework() { echo "$1/Resources/TabsBuildStamp.plist"; }
stamp_of_plugin() { echo "$1/Contents/Resources/TabsBuildStamp.plist"; }
app_stamp="$app/Contents/Resources/TabsBuildStamp.plist"

# Dependencies of an image (all architecture slices), minus its own install name.
deps_of() {
  local self_id
  self_id="$(otool -D "$1" | grep -v ':$' | head -1)"
  otool -L "$1" | grep -v ':$' | awk '{print $1}' | sort -u | grep -vxF "${self_id:-/nonexistent}"
}

# 1. One SDK.
copies=0
for image in ${images[@]+"${images[@]}"}; do [ "$(basename "$image")" = TabsPluginSDK ] && copies=$((copies + 1)); done
[ "$copies" -eq 1 ] && pass "one TabsPluginSDK image" || fail "$copies TabsPluginSDK images in the bundle"
embedders=()
for image in ${images[@]+"${images[@]}"}; do
  [ "$image" = "$sdk_binary" ] && continue
  grep -q '_tabs_plugin_sdk_sentinel' <<< "$(nm -gU "$image" 2>/dev/null)" && embedders+=("$(rel "$image")")
done
[ ${#embedders[@]} -eq 0 ] && pass "no image embeds its own copy of the SDK" \
  || fail "statically linked SDK copies in: ${embedders[*]}"

# 2. Roles.
role_problems=0
for fw in ${frameworks[@]+"${frameworks[@]}"}; do
  role="$(plist "$(stamp_of_framework "$fw")" role)"
  name="$(basename "$fw" .framework)"
  case "$role" in
    sdk|core) ;;
    *) fail "$(rel "$fw") has role \"${role:-none}\" (expected sdk or core)"; role_problems=$((role_problems + 1)) ;;
  esac
done
for plugin in ${plugins[@]+"${plugins[@]}"}; do
  role="$(plist "$(stamp_of_plugin "$plugin")" role)"
  [ "$role" = plugin ] || { fail "$(rel "$plugin") has role \"${role:-none}\""; role_problems=$((role_problems + 1)); }
  # MH_BUNDLE, not a dylib: nothing can link against a plugin, only load it.
  grep -q 'Mach-O .*bundle' <<< "$(file -b "$(executable_of "$plugin")")" \
    || { fail "$(rel "$plugin") is not a Mach-O bundle"; role_problems=$((role_problems + 1)); }
done
[ "$role_problems" -eq 0 ] && pass "roles: ${#frameworks[@]} frameworks, ${#plugins[@]} plugin bundles"

# 3. Linkage.
linkage_problems=0
for image in ${images[@]+"${images[@]}"}; do
  [ "$image" = "$sdk_binary" ] && continue
  deps="$(deps_of "$image")"
  if grep -q 'TabsPluginSDK' <<< "$deps" && ! grep -qxF "$sdk_install_name" <<< "$deps"; then
    fail "$(rel "$image") binds the SDK by something other than $sdk_install_name: $(echo "$deps" | tr '\n' ' ')"
    linkage_problems=$((linkage_problems + 1))
  fi
done
for plugin in ${plugins[@]+"${plugins[@]}"}; do
  while IFS= read -r dep; do
    case "$dep" in
      (/usr/lib/*|/System/*|"$sdk_install_name") ;;
      (*) fail "$(rel "$plugin") links $dep (plugins may link only system libraries and the SDK)"
          linkage_problems=$((linkage_problems + 1)) ;;
    esac
  done < <(deps_of "$(executable_of "$plugin")")
done
[ "$linkage_problems" -eq 0 ] && pass "linkage: SDK by @rpath everywhere; plugins link only system libraries and the SDK"

# 4. Fingerprints.
configuration="$(plist "$app_stamp" configuration)"
expected="$("$here/shared-fingerprint.sh" "${configuration:-unknown}")"
mismatches=0
stamps=("$app_stamp")
for fw in ${frameworks[@]+"${frameworks[@]}"}; do stamps+=("$(stamp_of_framework "$fw")"); done
for plugin in ${plugins[@]+"${plugins[@]}"}; do stamps+=("$(stamp_of_plugin "$plugin")"); done
for stamp in "${stamps[@]}"; do
  got="$(plist "$stamp" fingerprint)"
  [ "$got" = "$expected" ] || { fail "$(rel "$stamp") fingerprint ${got:-missing}, $configuration sources say $expected"; mismatches=$((mismatches + 1)); }
done
[ "$mismatches" -eq 0 ] && pass "every image stamped $expected ($configuration, matches sources)"

# 5. Bundled plugins.
bundled="$(plist "$app_stamp" bundledPlugins | sed -n 's/^ *//; /^Array {$/d; /^}$/d; p' | sort)"
present="$(for p in ${plugins[@]+"${plugins[@]}"}; do basename "$p" .tabsplugin; done | sort)"
if [ "$bundled" = "$present" ]; then
  pass "bundled plugins match PlugIns ($(echo $bundled))"
else
  fail "bundled plugins [$(echo $bundled)] != PlugIns [$(echo $present)]"
fi
bad_ids=0
for plugin in ${plugins[@]+"${plugins[@]}"}; do
  name="$(basename "$plugin" .tabsplugin)"
  id="$(plist "$plugin/Contents/Info.plist" TabsPlugin:id)"
  [ "$id" = "$name" ] || { fail "$name.tabsplugin declares id \"$id\""; bad_ids=$((bad_ids + 1)); }
done
[ "$bad_ids" -eq 0 ] && pass "manifest ids match bundle names"

# 6. Readable by everyone: an install owned by another user (a pkg installed
#    as root) must still be able to read every file, or core refuses to start.
unreadable="$(find "$app" \( -type f ! -perm -o+r \) -o \( -type d ! -perm -o+rx \) 2>/dev/null | sed "s#^$app/##")"
if [ -z "$unreadable" ]; then
  pass "every file is world-readable"
else
  fail "not readable by other users: $(echo $unreadable)"
fi

# 7. Signature.
if signature="$(codesign --verify --deep --strict "$app" 2>&1)"; then
  pass "codesign --verify --deep --strict"
else
  fail "codesign: $signature"
fi

# 8. Headless activation.
data="$(mktemp -d)"
report="$(TABS_DATA_DIR="$data" "$app/Contents/MacOS/Tabs" --plugin-report 2>"$data/stderr")"
status=$?
if [ $status -eq 0 ]; then
  pass "--plugin-report: every plugin active ($(echo "$report" | grep -c '"state" : "active"'))"
else
  fail "--plugin-report exited $status:"
  echo "$report"
fi
if grep -q 'is implemented in both' "$data/stderr"; then
  fail "Objective-C runtime reports duplicate classes:"
  grep 'implemented in both' "$data/stderr"
fi
rm -rf "$data"

# 9. Launched.
data="$(mktemp -d)"
socket="/tmp/tabs-verify-$$.sock"
TABS_DATA_DIR="$data" TABS_LISTEN_SOCKET="$socket" TABS_E2E_HIDDEN=1 "$app/Contents/MacOS/Tabs" 2>"$data/stderr" &
pid=$!
ask() { printf '%s\n' "$1" | nc -U -w 5 "$socket" 2>/dev/null; }
info=""
for _ in $(seq 1 100); do  # up to ~10s
  kill -0 "$pid" 2>/dev/null || break
  info="$(ask '{"command":"tabs.info"}')"
  [ -n "$info" ] && break
  sleep 0.1
done
plugin_states="$(ask '{"command":"tabs.plugins"}')"
if ! grep -q '"ok":true' <<< "$info"; then
  fail "the launched app didn't answer tabs.info on its socket: ${info:-no answer} $(cat "$data/stderr")"
elif grep -q '"state":"\(failed\|rejected\)"' <<< "$plugin_states"; then
  fail "the launched app has plugins that aren't active: $plugin_states"
else
  pass "launched: answers on its control socket, $(echo "$plugin_states" | grep -o '"state":"active"' | wc -l | tr -d ' ') plugins active"
fi
kill -TERM "$pid" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then
  kill -KILL "$pid" 2>/dev/null
  fail "the launched app didn't quit on SIGTERM"
fi
wait "$pid" 2>/dev/null
rm -f "$socket"
rm -rf "$data"

# 10. The bundled skill (Settings ▸ AI symlinks this directory into an agent's skills; the
#     agent's shell runs its tabs-ctl as a plain process, so it must be real, executable files).
skill_source="$here/../Sources/Tabs/Resources/skills/tabs"
skill_bundled="$app/Contents/Resources/skills/tabs"
skill_problems=0
[ -f "$skill_bundled/SKILL.md" ] || { fail "the bundle has no skills/tabs/SKILL.md"; skill_problems=$((skill_problems + 1)); }
[ -x "$skill_bundled/scripts/tabs-ctl" ] || { fail "skills/tabs/scripts/tabs-ctl is missing or not executable"; skill_problems=$((skill_problems + 1)); }
if [ ! -d "$skill_source" ]; then
  fail "the source skill directory $skill_source is missing"
  skill_problems=$((skill_problems + 1))
elif difference="$(diff -r "$skill_source" "$skill_bundled" 2>&1)"; then
  :
else
  fail "the bundled skill differs from Sources/Tabs/Resources/skills/tabs: $(echo "$difference" | head -3 | tr '\n' ' ')"
  skill_problems=$((skill_problems + 1))
fi
[ "$skill_problems" -eq 0 ] && pass "bundled skill: SKILL.md and an executable tabs-ctl, identical to Sources/Tabs/Resources/skills/tabs"

# 11. The relay (the skill's scripts/tabs-ctl is a stub that runs it).
relay="$app/Contents/Helpers/tabs-ctl"
relay_problems=0
if [ ! -x "$relay" ] || ! grep -q 'Mach-O.*executable' <<< "$(file -b "$relay")"; then
  fail "Contents/Helpers/tabs-ctl is missing or not a Mach-O executable"
  relay_problems=$((relay_problems + 1))
else
  app_archs="$(lipo -archs "$(executable_of "$app")")"
  relay_archs="$(lipo -archs "$relay")"
  if [ "$relay_archs" != "$app_archs" ]; then
    fail "tabs-ctl is built for $relay_archs, the app for $app_archs"
    relay_problems=$((relay_problems + 1))
  fi
  while IFS= read -r dep; do
    case "$dep" in
      (/usr/lib/*|/System/*) ;;
      (*) fail "tabs-ctl links $dep (it may link only system libraries)"; relay_problems=$((relay_problems + 1)) ;;
    esac
  done < <(deps_of "$relay")
  # Outside a pane: the relay's own refusal. The stub's would mean it never found the relay.
  answer="$(env -i PATH=/usr/bin:/bin "$skill_bundled/scripts/tabs-ctl" ping 2>&1)"
  status=$?
  if [ $status -ne 1 ] || ! grep -q 'not running inside a Tabs terminal pane' <<< "$answer"; then
    fail "the skill's tabs-ctl didn't reach the relay (exit $status): $answer"
    relay_problems=$((relay_problems + 1))
  fi
fi
[ "$relay_problems" -eq 0 ] && pass "relay: Contents/Helpers/tabs-ctl ($relay_archs), system libraries only, reached by the skill's tabs-ctl"

# 12. Versions.
expected_version="$(sed -n 's/^MARKETING_VERSION = //p' "$here/../Config/Version.xcconfig")"
version_problems=0
for bundle in "$app" ${frameworks[@]+"${frameworks[@]}"} ${plugins[@]+"${plugins[@]}"}; do
  info="$bundle/Contents/Info.plist"
  [ -f "$info" ] || info="$bundle/Resources/Info.plist"
  for key in CFBundleShortVersionString CFBundleVersion; do
    got="$(plist "$info" "$key")"
    [ -n "$expected_version" ] && [ "$got" = "$expected_version" ] && continue
    fail "${bundle##*/} $key is \"$got\", Config/Version.xcconfig says \"$expected_version\""
    version_problems=$((version_problems + 1))
  done
done
# The relay's Info.plist is a section of its binary.
relay_info="$(otool -arch "$(lipo -archs "$relay" 2>/dev/null | awk '{print $1}')" -P "$relay" 2>/dev/null | sed -n '/^<?xml/,$p')"
for key in CFBundleShortVersionString CFBundleVersion; do
  got="$(printf '%s' "$relay_info" | plutil -extract "$key" raw -o - - 2>/dev/null)"
  [ -n "$expected_version" ] && [ "$got" = "$expected_version" ] && continue
  fail "tabs-ctl $key is \"$got\", Config/Version.xcconfig says \"$expected_version\""
  version_problems=$((version_problems + 1))
done
[ "$version_problems" -eq 0 ] && pass "every image's version is Config/Version.xcconfig's ($expected_version)"

echo
if [ "$failures" -eq 0 ]; then
  echo "verify-app: all checks passed"
else
  echo "verify-app: $failures failure(s)"
  exit 1
fi
