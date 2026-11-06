#!/bin/sh
# build-app.sh refuses what would lose a take or a folder, before it builds or quits anything: a
# debug flag's path it cannot resolve, a flag with no value, and a --stage that is not an .app.
# A swift that always fails keeps this test from building or opening anything if a guard is lost.
set -u
cd "$(dirname "$0")/../.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/folder"
touch "$work/folder/kept"
printf '#!/bin/sh\nexit 1\n' > "$work/bin/swift"
chmod +x "$work/bin/swift"

fail=0

refuses() {
  PATH="$work/bin:$PATH" sh scripts/build-app.sh "$@" >/dev/null 2>&1
  if [ $? -ne 2 ]; then
    echo "build-app.sh $* was not refused" >&2
    fail=1
  fi
}

refuses --run --record-call no/such/folder/call.wav
refuses --run --fake-mic no/such/folder/line.wav
refuses --run --voice-instructions no/such/folder/voice.txt
refuses --run --record-call
refuses --run --record-call ""
refuses --stage "$work/folder"
if [ ! -f "$work/folder/kept" ]; then
  echo "--stage replaced a folder that is not an .app" >&2
  fail=1
fi

exit $fail
