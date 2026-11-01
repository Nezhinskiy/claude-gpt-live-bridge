#!/bin/sh
# Every check CI runs. Later changes append their own checks below.
set -eu
cd "$(dirname "$0")/.."

swift format lint --strict -r app
(cd app && swift build && swift test)

# The mod's pure modules: type check and unit tests (typescript is the one dev dependency).
[ -d plugin/node_modules ] || npm --prefix plugin ci --no-audit --no-fund
npm --prefix plugin run typecheck
npm --prefix plugin run test:unit
