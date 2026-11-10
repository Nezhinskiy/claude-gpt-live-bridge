#!/bin/sh
# Three guards for a release: the marketplace pins the mod to the tag of the app's version, so an
# update installs the mod that belongs to the app; a release binary has no way to point the
# update check elsewhere (LIVEBRIDGE_RELEASES_URL exists in debug builds only); and neither the
# binary nor the audio page it ships reads the call's statistics (`--call-stats` exists in debug
# builds only, because the README promises no telemetry).
set -eu
cd "$(dirname "$0")/../.."

fail=0

version=$(plutil -extract CFBundleShortVersionString raw app/Support/Info.plist)
ref=$(plutil -extract plugins.0.source.ref raw .claude-plugin/marketplace.json 2>/dev/null || echo)
if [ "$ref" != "v$version" ]; then
  echo "marketplace.json pins the mod to \"$ref\" but the app is v$version" >&2
  fail=1
fi

if ! (cd app && swift build -c release >/dev/null); then
  echo "the release build failed" >&2
  exit 1
fi
binary="$(cd app && swift build -c release --show-bin-path)/LiveBridge"
if [ ! -s "$binary" ]; then
  echo "the release binary $binary is missing or empty" >&2
  exit 1
fi
if grep -a -q LIVEBRIDGE_RELEASES_URL "$binary"; then
  echo "the release binary contains LIVEBRIDGE_RELEASES_URL" >&2
  fail=1
fi
bundle="$(dirname "$binary")/LiveBridge_LiveBridge.bundle"
if [ ! -d "$bundle" ]; then
  echo "the release audio page $bundle is missing" >&2
  exit 1
fi
for needle in getStats packetsLost callStats; do
  if grep -a -q -r -e "$needle" "$binary" "$bundle"; then
    echo "the release binary or its audio page contains $needle" >&2
    fail=1
  fi
done

exit $fail
