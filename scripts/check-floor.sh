#!/bin/sh
# Runs the mod's engine-facing checks on the lowest Claude Code the README promises, so the type
# check, validation and tests must pass on that version; a need none of them reach still passes.
# A mod cannot declare a minimum (ADR 0001, item p), so this run is what holds the number to the
# code. README.md's Requirements line is the number's home: change it there and this run follows.
# CI runs this after check.sh, which installs plugin/node_modules. It downloads that Claude Code,
# so check.sh does not run it. --print prints the number and stops.
set -eu
cd "$(dirname "$0")/.."

fail() {
  echo "check-floor.sh: $1" >&2
  exit 1
}

floor=$(sed -n 's/^- Claude Code \([0-9]*\.[0-9]*\.[0-9]*\) or later.*/\1/p' README.md)
case "$floor" in
  '' | *[!0-9.]*) fail "README.md's Requirements do not state one Claude Code version" ;;
esac
if [ "${1:-}" = --print ]; then
  echo "$floor"
  exit 0
fi

dir=$(mktemp -d "${TMPDIR:-/tmp}/livebridge-floor.XXXXXX")
trap 'rm -rf "$dir"' EXIT

npm install --prefix "$dir" --no-audit --no-fund "@anthropic-ai/claude-code@$floor"
PATH="$dir/node_modules/.bin:$PATH"
found=$(claude --version)
case "$found" in
  "$floor "*) ;;
  *) fail "wanted Claude Code $floor but claude is $found" ;;
esac
echo "check-floor.sh: running the mod's checks on $found"
sh scripts/check-mod.sh
