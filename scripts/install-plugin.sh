#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
marketplace="${CC_RELAY_MARKETPLACE:-$project_root/Plugins}"

claude_cli="${CLAUDE_CLI:-}"
if [[ -z "$claude_cli" ]]; then
    claude_cli="$(command -v claude || true)"
fi
if [[ -z "$claude_cli" || ! -x "$claude_cli" ]]; then
    echo "Set CLAUDE_CLI to an executable Claude Code CLI path." >&2
    exit 1
fi
export CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1

# The bundled app already contains its worker. Source installs stage a complete marketplace,
# leaving source files and any running cached plugin untouched until the normal install below.
if [[ ! -x "$marketplace/cc-relay/bin/CompanionNativeWorker" ]]; then
    if [[ "$marketplace" != "$project_root/Plugins" || ! -f "$project_root/Package.swift" ]]; then
        echo "The native command worker is missing. Use the built app's marketplace or the source install script." >&2
        exit 1
    fi
    swift build --disable-sandbox --disable-keychain --configuration release \
        --scratch-path "$project_root/.build" --product CompanionNativeWorker
    worker_bin="$(swift build --disable-sandbox --disable-keychain --configuration release \
        --scratch-path "$project_root/.build" --show-bin-path | tail -n 1)/CompanionNativeWorker"
    staged_marketplace="$project_root/build/plugin-marketplace"
    mkdir -p "$staged_marketplace"
    rsync -a --exclude '.DS_Store' "$marketplace/" "$staged_marketplace/"
    mkdir -p "$staged_marketplace/cc-relay/bin"
    cp "$worker_bin" "$staged_marketplace/cc-relay/bin/CompanionNativeWorker"
    chmod +x "$staged_marketplace/cc-relay/bin/CompanionNativeWorker"
    codesign --force --sign - "$staged_marketplace/cc-relay/bin/CompanionNativeWorker"
    marketplace="$staged_marketplace"
fi

"$claude_cli" plugin validate "$marketplace/cc-relay"
"$claude_cli" plugin validate "$marketplace"

settings="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
mkdir -p "$(dirname "$settings")"
python3 - "$settings" <<'PY'
import json
import os
import pathlib
import shutil
import sys
import tempfile
from datetime import datetime, timezone

path = pathlib.Path(sys.argv[1])
if path.is_symlink():
    raise SystemExit("Refusing a symlinked Claude settings file")
if path.exists():
    if not path.is_file():
        raise SystemExit("Claude settings path is not a regular file")
    settings = json.loads(path.read_text(encoding="utf-8"))
else:
    settings = {}
if not isinstance(settings, dict):
    raise SystemExit("Claude settings root must be an object")
environment = settings.get("env", {})
if not isinstance(environment, dict):
    raise SystemExit("Claude settings env must be an object")
if environment.get("CLAUDE_CODE_ENABLE_FUNCTION_HOOKS") == "1":
    raise SystemExit(0)
if path.exists():
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    backup = path.with_name(f"settings.json.cc-relay-backup-{stamp}")
    index = 1
    while backup.exists():
        backup = path.with_name(f"settings.json.cc-relay-backup-{stamp}-{index}")
        index += 1
    shutil.copy2(path, backup)
    os.chmod(backup, 0o600)
environment["CLAUDE_CODE_ENABLE_FUNCTION_HOOKS"] = "1"
settings["env"] = environment
fd, temporary = tempfile.mkstemp(prefix=".settings.cc-relay-", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(settings, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY

(
    cd "$(dirname "$marketplace")"
    "$claude_cli" plugin marketplace add "./$(basename "$marketplace")"
)
"$claude_cli" plugin install cc-relay@cc-relay-local
"$claude_cli" plugin list
