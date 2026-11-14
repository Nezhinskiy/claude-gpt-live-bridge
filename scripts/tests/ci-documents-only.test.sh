#!/bin/sh
# CI's long check is skipped only for a change that nothing in it could fail on. A scratch repository
# holds each kind of change; anything but a document, a rename out of code, or a change to a line
# the check reads from a document must run it. ci.yml must run the check when the answer is missing.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
detector="$root/scripts/ci-documents-only.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/livebridge-docs-only.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0

problem() {
  echo "$1" >&2
  fail=1
}

cd "$tmp"
git init -q
git config user.email test@example.com
git config user.name Example
mkdir -p app plugin/skills docs site/assets .github/workflows .github/ISSUE_TEMPLATE scripts
echo 'let a = 1' >app/a.swift
echo 'skill' >plugin/skills/a.md
echo 'doc' >docs/a.md
echo 'body{}' >site/style.css
echo 'scratch' >scripts/a.sh
echo 'on: push' >.github/workflows/a.yml
printf -- '- Claude Code 2.1.301 or later\nProse\n' >README.md
printf '<p>Claude Code 2.1.301</p>\n<p>Prose</p>\n' >site/index.html
git add -A
git commit -qm base

# Name, then whether the change in the working tree is documents only (yes or no).
expect() {
  git add -A
  git commit -qm change --allow-empty
  if sh "$detector" HEAD^1 HEAD; then got=yes; else got=no; fi
  [ "$got" = "$2" ] || problem "$1: wanted $2, got $got"
  git reset -q --hard HEAD^1
}

echo more >>docs/a.md
expect 'a file under docs' yes
echo new >CHANGELOG.md
expect 'a Markdown file at the root' yes
mkdir -p docs/i18n && echo text >docs/i18n/README.ru.md
expect 'a translation' yes
echo text >LICENSE
expect 'the license' yes
echo 'a{}' >>site/style.css
expect 'the site style sheet' yes
echo image >site/assets/a.png
expect 'a site image' yes
echo 'name: bug' >.github/ISSUE_TEMPLATE/a.yml
expect 'an issue form' yes
sed -i.bak 's/Prose/Better prose/' README.md && rm README.md.bak
expect 'prose in the README' yes
sed -i.bak 's/Prose/Better prose/' site/index.html && rm site/index.html.bak
expect 'prose on the site' yes
echo text >.github/pull_request_template.md
expect 'the pull request template' yes

sed -i.bak 's/2.1.301/2.1.302/' README.md && rm README.md.bak
expect 'the Claude Code floor in the README' no
sed -i.bak 's/2.1.301/2.1.302/' site/index.html && rm site/index.html.bak
expect 'the Claude Code floor on the site' no
sed -i.bak '/Claude Code/d' README.md && rm README.md.bak
expect 'the floor line removed' no
echo '- Claude Code 2.1.400 or later' >>README.md
expect 'a floor line added' no
echo note >README.fr.md
expect 'another README at the root, which the check reads' no
mkdir -p app/x && echo note >app/x/a.md
expect 'Markdown under app' no
mkdir -p wire/fixtures && echo note >wire/fixtures/a.md
expect 'Markdown beside the wire fixtures' no
echo note >scripts/a.md
expect 'Markdown among the scripts' no
echo 'let b = 2' >>app/a.swift
expect 'code' no
echo more >>docs/a.md
echo 'let b = 2' >>app/a.swift
expect 'code with a document' no
echo more >>plugin/skills/a.md
expect 'Markdown the mod ships' no
echo more >>scripts/a.sh
expect 'a script' no
echo 'on: pull_request' >.github/workflows/a.yml
expect 'a workflow' no
git mv app/a.swift docs/a.swift
expect 'a file moved out of the code' no
expect 'an empty change' no

# The workflow asks this script and acts only on its yes: any other answer runs the check.
# GitHub counts a job its own condition skipped as passed, so the check job always runs and decides
# inside: on a pull request it fails unless `changes` succeeded, it fails a cancelled run, and it
# skips every other step, the suite's, for a documents-only change.
workflow="$root/.github/workflows/ci.yml"
job=$(sed -n '/^  check:/,$p' "$workflow")
for line in "    needs: changes" "    if: \${{ always() }}" \
  "      ANSWER: \${{ github.event_name == 'pull_request' && needs.changes.result || 'success' }}" \
  "      SUITE: \${{ needs.changes.outputs.documents-only != 'true' }}" \
  'run: test "$ANSWER" = success' "        if: \${{ cancelled() }}"; do
  printf '%s\n' "$job" | grep -qF -- "$line" || problem "ci.yml's check job must have: $line"
done
[ "$(printf '%s\n' "$job" | grep -c '^    if:' || true)" = 1 ] ||
  problem "ci.yml's check job must have no condition but always()"
steps=$(printf '%s\n' "$job" | grep -c '^      - ' || true)
gated=$(printf '%s\n' "$job" | grep -cxF "        if: env.SUITE == 'true'" || true)
[ "$gated" = $((steps - 2)) ] ||
  problem "ci.yml's check job must skip each step but the answer's and the cancel's for documents only"
grep -qF 'if sh scripts/ci-documents-only.sh HEAD^1 HEAD; then' "$workflow" ||
  problem "ci.yml must ask scripts/ci-documents-only.sh about the pull request's own change"

exit "$fail"
