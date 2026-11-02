#!/bin/sh
# Every check CI runs.
set -eu
cd "$(dirname "$0")/.."

swift format lint --strict -r app
(cd app && swift build && swift test)
# build-app.sh --uninstall removes exactly what the app keeps.
sh scripts/tests/uninstall.test.sh
# The marketplace pins the mod to the app's release tag; a release binary has no test-only switch.
sh scripts/tests/release-guards.test.sh
# The audio page's pure modules (voice detection, pre-roll and catch-up).
node --test app/Tests/AudioJSTests

# The mod's pure modules and their unit tests: TypeScript and @types/node, its dev dependencies.
[ -d plugin/node_modules/@types/node ] || npm --prefix plugin ci --no-audit --no-fund
npm --prefix plugin run typecheck:pure
npm --prefix plugin run test:unit
# The mod and the app ship as one release under one version.
app_version=$(plutil -extract CFBundleShortVersionString raw app/Support/Info.plist)
mod_version=$(node -p "require('./plugin/.claude-plugin/plugin.json').version")
if [ "$app_version" != "$mod_version" ]; then
  echo "check.sh: Info.plist says $app_version but plugin.json says $mod_version" >&2
  exit 1
fi

# The mod's engine-facing half (register.tsx, link.ts, band.tsx, context.ts and the engine
# tests) needs Claude Code: the API types it lays beside a mod it loads, and `claude plugin`.
# CI installs it (.github/workflows/ci.yml), so there a missing `claude` fails the run.
if ! command -v claude >/dev/null 2>&1; then
  if [ -n "${CI:-}" ]; then
    echo "check.sh: claude is not on PATH" >&2
    exit 1
  fi
  echo "check.sh: claude is not on PATH, so the mod's engine-facing half was NOT type-checked or tested; install Claude Code and run this again" >&2
  exit 0
fi
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
