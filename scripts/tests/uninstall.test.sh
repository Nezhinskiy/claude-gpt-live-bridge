#!/bin/sh
# `build-app.sh --uninstall` removes the app and exactly the files it keeps, leaves every
# neighbour alone, and only prints the permission reset. Runs against a scratch HOME, with a
# scratch folder standing in for /Applications.
set -eu
cd "$(dirname "$0")/../.."

home=$(mktemp -d "${TMPDIR:-/tmp}/livebridge-uninstall.XXXXXX")
trap 'rm -rf "$home"' EXIT
id=com.getlivebridge.livebridge
lib="$home/Library"
apps="$home/Applications-root"

ours="$apps/LiveBridge.app
$lib/Application Support/LiveBridge
$lib/Caches/$id
$lib/WebKit/$id
$lib/HTTPStorages/$id
$lib/HTTPStorages/$id.binarycookies
$lib/Preferences/$id.plist"
theirs="$apps/Other.app
$home/Applications/LiveBridge.app
$lib/Application Support/LiveBridge-notes
$lib/Caches/com.getlivebridge.other
$lib/WebKit/com.example.browser
$lib/Preferences/com.example.app.plist"

printf '%s\n%s\n' "$ours" "$theirs" | while IFS= read -r path; do
  case "$path" in
    *.plist | *.binarycookies) mkdir -p "$(dirname "$path")" && : >"$path" ;;
    *) mkdir -p "$path/inner" ;;
  esac
done

out=$(HOME="$home" LIVEBRIDGE_APPLICATIONS="$apps" scripts/build-app.sh --uninstall)

fail=0
if HOME='' LIVEBRIDGE_APPLICATIONS="$apps" scripts/build-app.sh --uninstall 2>/dev/null; then
  echo "ran with an empty HOME"
  fail=1
fi
echo "$ours" | while IFS= read -r path; do
  [ ! -e "$path" ] || { echo "not removed: $path"; exit 1; }
done || fail=1
echo "$theirs" | while IFS= read -r path; do
  [ -e "$path" ] || { echo "removed a neighbour: $path"; exit 1; }
done || fail=1
case "$out" in
  *"tccutil reset Microphone $id"*) ;;
  *) echo "the microphone reset is not printed"; fail=1 ;;
esac
[ "$fail" = 0 ] && echo "uninstall.test.sh: ok"
exit "$fail"
