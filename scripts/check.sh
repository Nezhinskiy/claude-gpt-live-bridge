#!/bin/sh
# Every check CI runs but one: scripts/check-floor.sh, which downloads a second Claude Code.
set -eu
cd "$(dirname "$0")/.."

swift format lint --strict -r app
(cd app && swift build && swift test)
# build-app.sh --uninstall removes exactly what the app keeps.
sh scripts/tests/uninstall.test.sh
# The marketplace pins the mod to the app's release tag; a release binary has no test-only switch.
sh scripts/tests/release-guards.test.sh
# Every copy of the lowest Claude Code the README promises agrees with its Requirements line.
sh scripts/tests/claude-code-floor.test.sh
# The audio page's pure modules (voice detection, pre-roll and catch-up).
node --test 'app/Tests/AudioJSTests/*.test.mjs'

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
sh scripts/check-mod.sh
