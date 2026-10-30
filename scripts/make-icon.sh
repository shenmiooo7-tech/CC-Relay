#!/usr/bin/env bash
set -euo pipefail

# Renders AppIconArtwork into Resources/AppIcon.icns. Run it after changing the artwork or the buddy's face
# (BuddyArt), then commit the .icns.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
cache_root="$root/.build"
mkdir -p "$cache_root/cache" "$cache_root/config" "$cache_root/security" "$cache_root/clang-module-cache"
export CLANG_MODULE_CACHE_PATH="$cache_root/clang-module-cache"
swift_args=(--disable-sandbox --disable-keychain --configuration debug
    --scratch-path "$cache_root" --cache-path "$cache_root/cache"
    --config-path "$cache_root/config" --security-path "$cache_root/security")
swift build "${swift_args[@]}" --product CCRelay
bin_dir="$(swift build "${swift_args[@]}" --show-bin-path | tail -n 1)"
work="$(mktemp -d "${TMPDIR:-/tmp}/cc-relay-icon.XXXXXX")"
trap 'rm -rf "$work"' EXIT
"$bin_dir/CCRelay" --render-icon "$work/AppIcon.iconset"
iconutil --convert icns --output "$root/Resources/AppIcon.icns" "$work/AppIcon.iconset"
echo "Wrote Resources/AppIcon.icns"
