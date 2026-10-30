#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo 'Usage: scripts/test-all.sh'
            echo 'Runs Swift and Node regressions, and the plugin tests in Claude Code'"'"'s own test host when'
            echo 'a claude command is on PATH.'
            echo 'For selected Swift tests, use scripts/test.sh --filter TestName.'
            echo 'Set CC_RELAY_TEST_BUILD_ROOT to use a separate build directory (default: project .build).'
            exit 0
            ;;
        *) echo "[FAIL] Unknown argument: $1 (use --help)." >&2; exit 2 ;;
    esac
done

cache_root="${CC_RELAY_TEST_BUILD_ROOT:-$root/.build}"
if [[ "$cache_root" != /* ]]; then cache_root="$PWD/$cache_root"; fi
cd "$root"
mkdir -p "$cache_root/cache" "$cache_root/config" "$cache_root/security" "$cache_root/clang-module-cache"
export CC_RELAY_TEST=1
export CLANG_MODULE_CACHE_PATH="$cache_root/clang-module-cache"
swift_args=(--disable-sandbox --disable-keychain --configuration debug
    --scratch-path "$cache_root" --cache-path "$cache_root/cache"
    --config-path "$cache_root/config" --security-path "$cache_root/security")

failed=0
build_ready=false
test_config='' cli_config=''
trap 'rm -rf -- ${test_config:+"$test_config"} ${cli_config:+"$cli_config"}' EXIT
if swift build "${swift_args[@]}" --product FakeClaude &&
    swift build "${swift_args[@]}" --product CompanionNativeWorker &&
    bin_dir="$(swift build "${swift_args[@]}" --show-bin-path)" &&
    [[ -x "$bin_dir/CompanionNativeWorker" ]]; then
    build_ready=true
    echo '[PASS] Build: FakeClaude and CompanionNativeWorker from this checkout.'
else
    failed=1
    echo '[FAIL] Build: no previous worker will be used.' >&2
fi

if [[ "$build_ready" == true ]]; then
    if swift test "${swift_args[@]}"; then
        echo '[PASS] Swift regressions.'
    else
        failed=1
        echo '[FAIL] Swift regressions.' >&2
    fi

    test_config="$(mktemp -d "${TMPDIR:-/tmp}/cc-relay-test-config.XXXXXX")"
    if env "CC_RELAY_NATIVE_WORKER=$bin_dir/CompanionNativeWorker" "CLAUDE_CONFIG_DIR=$test_config" \
        node --test "$root"/Plugins/cc-relay/tests/*.test.js; then
        echo '[PASS] Node regressions.'
    else
        failed=1
        echo '[FAIL] Node regressions.' >&2
    fi
else
    echo '[SKIP] Swift and Node regressions: required build failed.'
fi

# Claude Code's own test host loads the whole plugin under its load rules, which the Node fixtures
# do not apply. It gets a throwaway config folder and opens no conversation.
if claude_cli="$(command -v claude)"; then
    cli_config="$(mktemp -d "${TMPDIR:-/tmp}/cc-relay-cli-config.XXXXXX")"
    if (cd "$root/Plugins/cc-relay" && env CLAUDE_CONFIG_DIR="$cli_config" \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 "$claude_cli" plugin test .); then
        echo "[PASS] Plugin tests in Claude Code's own test host (.test.ts)."
    else
        failed=1
        echo "[FAIL] Plugin tests in Claude Code's own test host (.test.ts)." >&2
    fi
else
    echo "[SKIP] Plugin tests in Claude Code's own test host (.test.ts): no claude command on PATH."
fi
echo '[SKIP] Real-account switch and comment/reply acceptance: requires a separate dedicated-session run.'
if [[ "$failed" == 0 ]]; then
    echo '[PASS] All selected local suites passed; skipped checks are not acceptance evidence.'
else
    echo '[FAIL] Local validation failed; see the stage output above.' >&2
fi
exit "$failed"
