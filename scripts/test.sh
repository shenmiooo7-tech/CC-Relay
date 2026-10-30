#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

cache_root="$root/.build"
mkdir -p \
    "$cache_root/cache" \
    "$cache_root/config" \
    "$cache_root/security" \
    "$cache_root/clang-module-cache"

export CC_RELAY_TEST=1
export CLANG_MODULE_CACHE_PATH="$cache_root/clang-module-cache"

swift_location_args=(
    --disable-sandbox
    --disable-keychain
    --scratch-path "$cache_root"
    --cache-path "$cache_root/cache"
    --config-path "$cache_root/config"
    --security-path "$cache_root/security"
)

# The end-to-end test launches this binary from the test bundle's products directory.
swift build --product FakeClaude "${swift_location_args[@]}"
swift build --product CompanionNativeWorker "${swift_location_args[@]}"
swift test "${swift_location_args[@]}" "$@"
