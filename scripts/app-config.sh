#!/usr/bin/env bash
# Bundle identity shared by the packaging scripts. Source this file; it has no side effects.
set -euo pipefail

CC_RELAY_BUNDLE_IDENTIFIER="local.cc-relay"
CC_RELAY_DISPLAY_NAME="CC-Relay"
CC_RELAY_EXECUTABLE_NAME="CCRelay"
CC_RELAY_MARKETING_VERSION="0.3.0"
CC_RELAY_BUILD_NUMBER="3"
CC_RELAY_MINIMUM_SYSTEM_VERSION="14.0"

# The commit a build is made from, shown in Settings and logged at startup; "+" marks uncommitted
# changes, new files included, since the build compiles those too. Empty outside a git checkout.
cc_relay_revision() {
    local revision
    revision="$(git -C "$1" rev-parse --short HEAD 2>/dev/null || true)"
    if [[ -n "$revision" && -n "$(git -C "$1" status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
        revision="$revision+"
    fi
    printf '%s' "$revision"
}
