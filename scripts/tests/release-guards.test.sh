#!/bin/sh
# Two guards for a release: the marketplace pins the mod to the tag of the app's version, so an
# update installs the mod that belongs to the app, and a release binary has no way to point the
# update check elsewhere (LIVEBRIDGE_RELEASES_URL exists in debug builds only). Neither has it the
# debug tools. Their flags are looked for through DebugFlags and CallTape, the types that hold them:
# Swift keeps a literal of up to 15 bytes in the instructions, where grep cannot see --fake-mic. The
# audio page's debug-*.js stay out as well.
set -eu
cd "$(dirname "$0")/../.."

fail=0

version=$(plutil -extract CFBundleShortVersionString raw app/Support/Info.plist)
ref=$(plutil -extract plugins.0.source.ref raw .claude-plugin/marketplace.json 2>/dev/null || echo)
if [ "$ref" != "v$version" ]; then
  echo "marketplace.json pins the mod to \"$ref\" but the app is v$version" >&2
  fail=1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
if ! sh scripts/build-app.sh --stage "$stage/LiveBridge.app" >/dev/null; then
  echo "the release build failed" >&2
  exit 1
fi
binary="$stage/LiveBridge.app/Contents/MacOS/LiveBridge"
if [ ! -s "$binary" ]; then
  echo "the release binary $binary is missing or empty" >&2
  exit 1
fi
for name in LIVEBRIDGE_RELEASES_URL DebugFlags CallTape --voice-instructions; do
  if grep -a -q -- "$name" "$binary"; then
    echo "the release binary contains $name" >&2
    fail=1
  fi
done

audio="$stage/LiveBridge.app/Contents/Resources/LiveBridge_LiveBridge.bundle/Contents/Resources/audio"
if [ ! -f "$audio/audio.js" ]; then
  echo "the staged release has no audio page" >&2
  fail=1
fi
if [ -n "$(find "$audio" -name 'debug-*')" ]; then
  echo "the staged release carries the audio page's debug tools" >&2
  fail=1
fi

exit $fail
