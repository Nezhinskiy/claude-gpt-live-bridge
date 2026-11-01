#!/bin/sh
# Builds LiveBridge.app (debug) from the SwiftPM package and signs it ad hoc.
#
#   scripts/build-app.sh                         build app/.build/app/LiveBridge.app
#   scripts/build-app.sh --run [--fake-mic WAV]  build, quit a running copy, open the new one
#
# --fake-mic (debug builds only) plays WAV as the microphone. If CFFIXED_USER_HOME is set, the
# app keeps its files under that directory instead of your home folder.
set -eu
cd "$(dirname "$0")/.."

run=no
if [ "${1:-}" = "--run" ]; then
  run=yes
  shift
fi

(cd app && swift build -c debug)
bin=$(cd app && swift build -c debug --show-bin-path)
app=app/.build/app/LiveBridge.app

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/LiveBridge" "$app/Contents/MacOS/LiveBridge"
cp app/Support/Info.plist "$app/Contents/Info.plist"
# Bundle.module looks for the resource bundle in Contents/Resources.
cp -R "$bin/LiveBridge_LiveBridge.bundle" "$app/Contents/Resources/"
[ -f app/Support/AppIcon.icns ] && cp app/Support/AppIcon.icns "$app/Contents/Resources/"
codesign --force --sign - --options runtime --entitlements app/Support/LiveBridge.entitlements \
  "$app"
echo "built $app"

[ "$run" = yes ] || exit 0
osascript -e 'quit app id "io.github.nezhinskiy.livebridge"' 2>/dev/null || true
if [ "${1:-}" = "--fake-mic" ] && [ -n "${2:-}" ]; then
  set -- --fake-mic "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
fi
if [ -n "${CFFIXED_USER_HOME:-}" ]; then
  open -n --env "CFFIXED_USER_HOME=$CFFIXED_USER_HOME" "$app" --args "$@"
else
  open -n "$app" --args "$@"
fi
