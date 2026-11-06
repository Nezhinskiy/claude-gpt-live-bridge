#!/bin/sh
# The lowest Claude Code the README promises is one fact, and it can fail. Every copy of it agrees
# with the Requirements line in README.md, ci.yml has the step that runs it, check.sh still runs
# the mod's checks, and the floor run fails when the mod does not pass on that version. The run
# goes in a scratch copy with a stand-in npm and claude, so nothing is downloaded and the tree's
# own types stay.
set -eu
cd "$(dirname "$0")/../.."

tmp=$(mktemp -d "${TMPDIR:-/tmp}/livebridge-floor.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0

problem() {
  echo "$1" >&2
  fail=1
}

floor=$(sh scripts/check-floor.sh --print)

# Quick start and Requirements in each README; the site's one sentence.
for file in README*.md site/index.html; do
  case "$file" in site/*) want=1 ;; *) want=2 ;; esac
  stated=$(grep -oE 'Claude Code [0-9]+\.[0-9]+\.[0-9]+' "$file" || true)
  count=$(printf '%s' "$stated" | grep -c . || true)
  [ "$count" -eq "$want" ] || problem "$file states the Claude Code floor $count times, not $want"
  other=$(printf '%s\n' "$stated" | grep -v -x "Claude Code $floor" | grep . || true)
  [ -z "$other" ] || problem "$file says $other but README.md's Requirements say $floor"
done

grep -Eq '^ +run: scripts/check-floor\.sh$' .github/workflows/ci.yml ||
  problem "ci.yml does not run scripts/check-floor.sh"
grep -q '^sh scripts/check-mod\.sh$' scripts/check.sh ||
  problem "check.sh does not run scripts/check-mod.sh"

# The scratch copy: the two scripts and the README. Each run finds types left by a higher version.
repo="$tmp/repo"
types=plugin/.claude-plugin/types/claude-code/index.d.ts
mkdir -p "$repo/scripts" "$repo/$(dirname "$types")" "$tmp/bin"
cp scripts/check-floor.sh scripts/check-mod.sh "$repo/scripts/"
cp README.md "$repo/"

# What `npm install` lays: a claude that reports $FAKE_CLAUDE_VERSION, or the version asked for.
cat >"$tmp/claude" <<'STUB'
#!/bin/sh
case "$1 ${2:-} ${3:-}" in
  "--version  ") echo "${FAKE_CLAUDE_VERSION:-$FAKE_REQUESTED} (Claude Code)" ;;
  "plugin validate plugin") [ "${FAKE_FAILS:-}" != validate ] ;;
  "plugin validate .") [ "${FAKE_FAILS:-}" != validate-root ] ;;
  "plugin test plugin") [ "${FAKE_FAILS:-}" != test ] ;;
  *) # The headless session that lays the types.
    echo "what the session printed"
    [ "${FAKE_FAILS:-}" != no-types ] || exit 0
    printf '// Written by Claude Code %s.\n' "${FAKE_CLAUDE_VERSION:-$FAKE_REQUESTED}" \
      >plugin/.claude-plugin/types/claude-code/index.d.ts
    [ "${FAKE_FAILS:-}" != session ]
    ;;
esac
STUB
cat >"$tmp/bin/npm" <<'STUB'
#!/bin/sh
if [ "$1" = install ]; then
  prefix=$3
  for last; do :; done
  mkdir -p "$prefix/node_modules/.bin"
  { echo '#!/bin/sh'; echo "FAKE_REQUESTED=${last##*@}"; cat "$FAKE_STUBS/claude"; } \
    >"$prefix/node_modules/.bin/claude"
  chmod +x "$prefix/node_modules/.bin/claude"
else
  # npm --prefix plugin run typecheck: record which version's types it saw.
  head -n 1 plugin/.claude-plugin/types/claude-code/index.d.ts >"$FAKE_STUBS/typechecked"
  [ "${FAKE_FAILS:-}" != typecheck ]
fi
STUB
chmod +x "$tmp/bin/npm"

run_floor() {
  printf '// Written by Claude Code 9.9.9.\n' >"$repo/$types"
  (cd "$repo" && env PATH="$tmp/bin:/usr/bin:/bin" FAKE_STUBS="$tmp" "$@" \
    sh scripts/check-floor.sh) >"$tmp/output" 2>&1
}

run_floor || problem "the floor run failed with a mod that passes"
if [ "$(cat "$tmp/typechecked" 2>/dev/null)" != "// Written by Claude Code $floor." ]; then
  problem "the floor run type-checked against types that are not the floor's"
fi

for failing in session no-types typecheck validate-root validate test; do
  if run_floor FAKE_FAILS="$failing"; then
    problem "the floor run passed though $failing failed on the floor"
  fi
done

run_floor FAKE_FAILS=session || true
grep -q "what the session printed" "$tmp/output" ||
  problem "a failed session said nothing about why"

if run_floor FAKE_CLAUDE_VERSION=9.9.9; then
  problem "the floor run passed on a claude that is not the floor"
fi

sed -i '' '/^- Claude Code /d' "$repo/README.md"
if run_floor; then
  problem "the floor run passed with no floor in README.md"
fi

exit $fail
