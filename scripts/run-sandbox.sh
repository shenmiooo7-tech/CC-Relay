#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/app-config.sh"
make_only=false
destination=""
for argument in "$@"; do
    case "$argument" in
        --make-only) make_only=true ;;
        --*) echo "Usage: scripts/run-sandbox.sh [--make-only] [dir]" >&2; exit 2 ;;
        *)
            if [[ -n "$destination" ]]; then
                echo "run-sandbox.sh: expected one destination" >&2
                exit 2
            fi
            destination="$argument"
            ;;
    esac
done
destination="${destination:-./sandbox}"
# Resolve relative destinations before changing the working directory for SwiftPM.
if [[ "$destination" != /* ]]; then destination="$PWD/$destination"; fi
cd "$root"
cache_root="$root/.build"
mkdir -p "$cache_root/cache" "$cache_root/config" "$cache_root/security" "$cache_root/clang-module-cache"
export CLANG_MODULE_CACHE_PATH="$cache_root/clang-module-cache"
swift_args=(--disable-sandbox --disable-keychain --configuration debug
    --scratch-path "$cache_root" --cache-path "$cache_root/cache"
    --config-path "$cache_root/config" --security-path "$cache_root/security")
swift build "${swift_args[@]}" --product CCRelay
swift build "${swift_args[@]}" --product FakeClaude
bin_dir="$(swift build "${swift_args[@]}" --show-bin-path | tail -n 1)"
# The hidden command returns before AppKit/SwiftUI startup and never assembles live adapters.
destination="$("$bin_dir/CCRelay" --make-sandbox "$destination")"
app="$destination/Applications/CC-Relay.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/CCRelay" "$app/Contents/MacOS/$CC_RELAY_EXECUTABLE_NAME"
sed \
    -e "s/__BUNDLE_ID__/${CC_RELAY_BUNDLE_IDENTIFIER}/g" \
    -e "s/__DISPLAY_NAME__/${CC_RELAY_DISPLAY_NAME}/g" \
    -e "s/__EXECUTABLE_NAME__/${CC_RELAY_EXECUTABLE_NAME}/g" \
    -e "s/__VERSION__/${CC_RELAY_MARKETING_VERSION}/g" \
    -e "s/__BUILD__/${CC_RELAY_BUILD_NUMBER}/g" \
    -e "s/__REVISION__/$(cc_relay_revision "$root")/g" \
    -e "s/__MIN_MACOS__/${CC_RELAY_MINIMUM_SYSTEM_VERSION}/g" \
    "$root/Resources/Info.plist.template" > "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
rsync -a --exclude '.DS_Store' "$root/Resources/Fonts/" "$app/Contents/Resources/Fonts/"
codesign --force --sign - "$app" >&2
printf 'Sandbox prepared. Run:\nCC_RELAY_SANDBOX=%q %q\n' "$destination" "$app/Contents/MacOS/$CC_RELAY_EXECUTABLE_NAME"
if [[ "$make_only" == false ]]; then
    exec env CC_RELAY_SANDBOX="$destination" "$app/Contents/MacOS/$CC_RELAY_EXECUTABLE_NAME"
fi
