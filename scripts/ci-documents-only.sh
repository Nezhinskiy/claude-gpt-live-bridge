#!/bin/sh
# Exits 0 when the change from commit $1 to commit $2 touches only documents, so CI's long check has
# nothing to fail on; exits 1 otherwise. An empty change, a file moved out of the code and a change
# to the Claude Code version the check reads from README.md or the site all count as code. Markdown
# under app/ or plugin/ does too: the mod ships its Markdown.
set -eu

files=$(git diff --no-renames --name-only "$1" "$2")

if ! printf '%s\n' "$files" | while IFS= read -r file; do
  case "$file" in
    app/* | plugin/*) exit 1 ;;
    docs/* | *.md | LICENSE | site/* | .github/ISSUE_TEMPLATE/*) ;;
    *) exit 1 ;;
  esac
done; then
  exit 1
fi

if git diff "$1" "$2" -- README.md site/index.html |
  grep -Eq '^[-+].*Claude Code [0-9]+\.[0-9]+\.[0-9]+'; then
  exit 1
fi
