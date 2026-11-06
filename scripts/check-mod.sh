#!/bin/sh
# The mod's engine-facing half, on the `claude` that is on PATH: the API types that version lays
# beside a mod it loads, the type check against them, `claude plugin validate` and `claude plugin
# test`. plugin/node_modules must be there; check.sh installs it.
set -eu
cd "$(dirname "$0")/.."

types=plugin/.claude-plugin/types/claude-code/index.d.ts
if [ ! -f "$types" ]; then
  # A headless session lays the types while it watches the mod's folder. The mod's own command
  # answers without the model, so this needs no login, and no settings or other plugins load.
  CLAUDE_CODE_PLUGIN_DIR_WATCH=1 claude -p --setting-sources "" --no-session-persistence \
    --plugin-dir plugin "/live status" >/dev/null
  [ -f "$types" ] || { echo "check.sh: Claude Code laid no API types in plugin/.claude-plugin/types" >&2; exit 1; }
fi
npm --prefix plugin run typecheck
claude plugin validate .
claude plugin validate plugin
claude plugin test plugin
