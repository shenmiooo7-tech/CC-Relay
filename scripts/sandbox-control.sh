#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo 'Usage: scripts/sandbox-control.sh <dir> <command> [arguments]' >&2
    exit 2
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="$1"
shift
# Use our built entry point: the supplied directory is validated before any action.
executable="$root/.build/debug/CCRelay"
if [[ ! -x "$executable" ]]; then
    executable="$root/build/CC-Relay.app/Contents/MacOS/CCRelay"
fi
if [[ ! -x "$executable" ]]; then
    echo 'sandbox-control.sh: build a sandbox with scripts/run-sandbox.sh --make-only first' >&2
    exit 1
fi
exec "$executable" --sandbox-control "$destination" "$@"
