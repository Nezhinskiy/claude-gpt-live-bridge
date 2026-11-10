#!/bin/sh
# Exits 0 when the change from commit $1 to commit $2 touches only documents, so CI's long check has
# nothing to fail on; exits 1 otherwise, and on any error. Only the listed places count: Markdown
# elsewhere in the tree can be read by a test or shipped with the mod. An empty change, a file moved
# out of the code, another README at the root and a change to the Claude Code version the check
# reads from README.md or the site (scripts/tests/claude-code-floor.test.sh) all run the check.
set -eu

files=$(git diff --no-renames --name-only "$1" "$2")

if ! printf '%s\n' "$files" | while IFS= read -r file; do
  case "$file" in
    docs/* | site/* | .github/ISSUE_TEMPLATE/* | .github/pull_request_template.md) ;;
    */* | README?*.md) exit 1 ;;
    *.md | LICENSE) ;;
    *) exit 1 ;;
  esac
done; then
  exit 1
fi

floor=$(git diff --text "$1" "$2" -- README.md site/index.html)
if printf '%s\n' "$floor" | grep -Eq '^[-+].*Claude Code [0-9]+\.[0-9]+\.[0-9]+'; then
  exit 1
fi
