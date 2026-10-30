#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
# shellcheck source=app-config.sh
source "$root/scripts/app-config.sh"

cache_root="$root/.build"
mkdir -p \
    "$cache_root/cache" \
    "$cache_root/config" \
    "$cache_root/security" \
    "$cache_root/clang-module-cache"

export CLANG_MODULE_CACHE_PATH="$cache_root/clang-module-cache"

swift_location_args=(
    --disable-sandbox
    --disable-keychain
    --configuration release
    # Emit DWARF in the compiler frontend, then link it below. Swift Build's
    # nested dsymutil invocation is refused in the agent sandbox.
    -debug-info-format none
    -Xswiftc -Xfrontend -Xswiftc -g
    --scratch-path "$cache_root"
    --cache-path "$cache_root/cache"
    --config-path "$cache_root/config"
    --security-path "$cache_root/security"
)

# `--show-bin-path` on its own prints the directory and skips the build.
swift build "${swift_location_args[@]}" --product "$CC_RELAY_EXECUTABLE_NAME"
swift build "${swift_location_args[@]}" --product CompanionNativeWorker
bin_dir="$(swift build "${swift_location_args[@]}" --show-bin-path | tail -n 1)"
binary="$bin_dir/$CC_RELAY_EXECUTABLE_NAME"
if [[ ! -x "$binary" ]]; then
    echo "build-app.sh: missing executable at $binary" >&2
    exit 1
fi

xcrun dsymutil "$binary" -o "$binary.dSYM"

app="$root/build/CC-Relay.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$binary" "$app/Contents/MacOS/$CC_RELAY_EXECUTABLE_NAME"
chmod +x "$app/Contents/MacOS/$CC_RELAY_EXECUTABLE_NAME"

# No Swift target declares resources. Never package stale SwiftPM bundles.
if [[ -n "$(find "$app/Contents/Resources" -mindepth 1 -print -quit)" ]]; then
    echo "build-app.sh: unexpected packaged resources" >&2
    exit 1
fi

# Finder's .DS_Store files stay out: the signature would seal them, and Finder rewrites them.
rsync -a --exclude '.DS_Store' "$root/Plugins/" "$app/Contents/Resources/Plugins/"
worker="$app/Contents/Resources/Plugins/cc-relay/bin/CompanionNativeWorker"
mkdir -p "$(dirname "$worker")"
cp "$bin_dir/CompanionNativeWorker" "$worker"
chmod +x "$worker"
codesign --force --sign - "$worker"

sed \
    -e "s/__BUNDLE_ID__/${CC_RELAY_BUNDLE_IDENTIFIER}/g" \
    -e "s/__DISPLAY_NAME__/${CC_RELAY_DISPLAY_NAME}/g" \
    -e "s/__EXECUTABLE_NAME__/${CC_RELAY_EXECUTABLE_NAME}/g" \
    -e "s/__VERSION__/${CC_RELAY_MARKETING_VERSION}/g" \
    -e "s/__BUILD__/${CC_RELAY_BUILD_NUMBER}/g" \
    -e "s/__REVISION__/$(cc_relay_revision "$root")/g" \
    -e "s/__MIN_MACOS__/${CC_RELAY_MINIMUM_SYSTEM_VERSION}/g" \
    "$root/Resources/Info.plist.template" > "$app/Contents/Info.plist"

plutil -lint "$app/Contents/Info.plist" >/dev/null
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# The wordmark's font with its licence; Info.plist's ATSApplicationFontsPath activates the folder.
rsync -a --exclude '.DS_Store' "$root/Resources/Fonts/" "$app/Contents/Resources/Fonts/"

codesign --force --sign - "$app/Contents/MacOS/$CC_RELAY_EXECUTABLE_NAME"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
