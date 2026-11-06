#!/bin/sh
# The mod's engine-facing half, on the `claude` that is on PATH: the API types that version lays
# beside a mod it loads, the type check against them, `claude plugin validate` and `claude plugin
# test`. plugin/node_modules must be there; check.sh installs it.
set -eu
cd "$(dirname "$0")/.."

# The types must be this version's: the type check would pass a call its own engine does not have
# against types left by a higher one. Their first line says who wrote them.
types=plugin/.claude-plugin/types/claude-code/index.d.ts
version=$(claude --version)
written="// Written by Claude Code ${version%% *}."
laid() { [ "$(head -n 1 "$types" 2>/dev/null)" = "$written" ]; }
if ! laid; then
  # A headless session lays the types while it watches the mod's folder. The mod's own command
  # answers without the model, so this needs no login, and no settings or other plugins load. If
  # the mod does not load, the command is only text to the model, and a logged-in session spends a
  # turn on it.
  CLAUDE_CODE_PLUGIN_DIR_WATCH=1 claude -p --setting-sources "" --no-session-persistence \
    --plugin-dir plugin "/live status" >&2
  laid || { echo "check-mod.sh: Claude Code laid no API types of its own version in plugin/.claude-plugin/types" >&2; exit 1; }
fi
npm --prefix plugin run typecheck
claude plugin validate .
claude plugin validate plugin
claude plugin test plugin
