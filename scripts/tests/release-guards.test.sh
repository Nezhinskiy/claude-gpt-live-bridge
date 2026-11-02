#!/bin/sh
# Two guards for a release: the marketplace pins the mod to the tag of the app's version, so an
# update installs the mod that belongs to the app, and a release binary has no way to point the
# update check elsewhere (LIVEBRIDGE_RELEASES_URL exists in debug builds only).
set -eu
cd "$(dirname "$0")/../.."

fail=0

version=$(plutil -extract CFBundleShortVersionString raw app/Support/Info.plist)
ref=$(plutil -extract plugins.0.source.ref raw .claude-plugin/marketplace.json 2>/dev/null || echo)
if [ "$ref" != "v$version" ]; then
  echo "marketplace.json pins the mod to \"$ref\" but the app is v$version" >&2
  fail=1
fi

(cd app && swift build -c release >/dev/null)
binary="$(cd app && swift build -c release --show-bin-path)/LiveBridge"
if grep -a -q LIVEBRIDGE_RELEASES_URL "$binary"; then
  echo "the release binary contains LIVEBRIDGE_RELEASES_URL" >&2
  fail=1
fi

exit $fail
