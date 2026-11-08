#!/bin/sh
# Has Apple notarize a signed LiveBridge.app or LiveBridge.dmg, staples the ticket to it and
# checks the result as Gatekeeper would:
#
#   scripts/notarize.sh dist/LiveBridge.app    zipped with ditto, submitted, stapled
#   scripts/notarize.sh dist/LiveBridge.dmg    submitted, stapled
#
# It needs an App Store Connect API key: LIVEBRIDGE_NOTARY_KEY is the path of its .p8 file,
# LIVEBRIDGE_NOTARY_KEY_ID its Key ID and LIVEBRIDGE_NOTARY_ISSUER its Issuer ID. Without them,
# or for any other file, it contacts nothing and exits 2. The file must already be signed with a
# Developer ID and a secure timestamp (scripts/build-app.sh --package-app and --package-dmg with
# LIVEBRIDGE_SIGN_IDENTITY). The release workflow (.github/workflows/release.yml) runs it.
set -eu

refuse() {
  echo "notarize.sh: $1" >&2
  exit 2
}

[ $# = 1 ] || refuse "usage: scripts/notarize.sh dist/LiveBridge.app | dist/LiveBridge.dmg"
file=${1%/}
for name in LIVEBRIDGE_NOTARY_KEY LIVEBRIDGE_NOTARY_KEY_ID LIVEBRIDGE_NOTARY_ISSUER; do
  [ -n "$(printenv "$name" || true)" ] || refuse "$name is not set"
done
[ -f "$LIVEBRIDGE_NOTARY_KEY" ] || refuse "LIVEBRIDGE_NOTARY_KEY names no file"
case "$file" in
  *.app) [ -d "$file" ] || refuse "$file is not an app" ;;
  *.dmg) [ -f "$file" ] || refuse "$file is not a disk image" ;;
  *) refuse "$file is neither a .app nor a .dmg" ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/livebridge-notarize.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# notarytool takes an archive, not a bundle; --keepParent keeps LiveBridge.app as its root.
submission=$file
case "$file" in
  *.app)
    submission="$tmp/LiveBridge.zip"
    ditto -c -k --keepParent "$file" "$submission"
    ;;
esac

# The verdict is read from the reply, not from the exit status, so only "Accepted" goes on.
answer="$tmp/submit.json"
xcrun notarytool submit "$submission" --key "$LIVEBRIDGE_NOTARY_KEY" \
  --key-id "$LIVEBRIDGE_NOTARY_KEY_ID" --issuer "$LIVEBRIDGE_NOTARY_ISSUER" \
  --wait --timeout 20m --output-format json >"$answer" || true
status=$(plutil -extract status raw -o - "$answer" 2>/dev/null || true)
id=$(plutil -extract id raw -o - "$answer" 2>/dev/null || true)
if [ "$status" != Accepted ]; then
  echo "notarize.sh: Apple did not accept $file (status: ${status:-none})" >&2
  cat "$answer" >&2
  if [ -n "$id" ]; then
    xcrun notarytool log "$id" --key "$LIVEBRIDGE_NOTARY_KEY" \
      --key-id "$LIVEBRIDGE_NOTARY_KEY_ID" --issuer "$LIVEBRIDGE_NOTARY_ISSUER" >&2 || true
  fi
  exit 1
fi
echo "notarized $file ($id)"

xcrun stapler staple "$file"
xcrun stapler validate "$file"
case "$file" in
  *.app) spctl --assess --type execute --verbose=2 "$file" ;;
  *.dmg) spctl --assess --type open --context context:primary-signature --verbose=2 "$file" ;;
esac
echo "stapled $file; Gatekeeper accepts it"
