#!/bin/bash
# Prints the shared-ABI fingerprint for a build configuration.
#
#   Scripts/shared-fingerprint.sh <configuration>
#
# Core, the SDK and plugins are compiled without library
# evolution, so every image hard-codes the layouts of the shared modules'
# types. The fingerprint must change whenever anything that can change those
# layouts changes:
#
#   - every file of every module whose types cross an image boundary — the SDK
#     (plugins ↔ core) and TabsCore (core ↔ the app shell) — path and content,
#     symlinks followed, not just .swift;
#   - the build configuration files: project.yml and every plugin's plugin.yml
#     (per-target flags, compilation conditions) and Config/*.xcconfig
#     (including an optional Signing.local.xcconfig);
#   - the configuration name (a Debug and a Release image never mix);
#   - the compiler (`swiftc --version` of the active toolchain).
#
# It is deliberately conservative: an edited comment changes it too. That only
# matters when images from different builds are mixed, which is exactly the
# case it exists to refuse.
set -euo pipefail

configuration="${1:?usage: shared-fingerprint.sh <configuration>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

{
  echo "configuration: $configuration"
  echo "compiler: $(xcrun swiftc --version 2>&1 | head -1)"
  { find -L Sources/TabsPluginSDK Sources/TabsCore project.yml Config -type f ! -name '.DS_Store' -print0
    find -L Plugins -name plugin.yml -type f -print0; } \
    | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256
} | shasum -a 256 | cut -c1-16
