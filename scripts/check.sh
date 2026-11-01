#!/bin/sh
# Every check CI runs.
set -eu
cd "$(dirname "$0")/.."

swift format lint --strict -r app
(cd app && swift build && swift test)
# build-app.sh --uninstall removes exactly what the app keeps.
sh scripts/tests/uninstall.test.sh
# The audio page's pure modules (voice detection, pre-roll and catch-up).
node --test app/Tests/AudioJSTests

# The mod: type check and unit tests (typescript is the one dev dependency). The engine-facing
# files type-check against the API types Claude Code lays in plugin/.claude-plugin/types once
# it has loaded the mod from that folder; without them only the pure modules are checked.
[ -d plugin/node_modules ] || npm --prefix plugin ci --no-audit --no-fund
if [ -f plugin/.claude-plugin/types/claude-code/index.d.ts ]; then
  npm --prefix plugin run typecheck
else
  echo "check.sh: no Claude Code API types in plugin/.claude-plugin/types; type-checking the pure modules only"
  npm --prefix plugin run typecheck:pure
fi
npm --prefix plugin run test:unit
if command -v claude >/dev/null 2>&1; then
  claude plugin validate .
  claude plugin validate plugin
  claude plugin test plugin
else
  echo "check.sh: claude is not on PATH; skipping the mod's validation and engine tests"
fi
