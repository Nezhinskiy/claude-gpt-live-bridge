#!/bin/sh
# `notarize.sh` refuses before contacting Apple when a credential or the file is wrong, staples
# only what Apple accepted, and submits an app as a zip. Stub `xcrun` and `spctl`, first on PATH,
# record each call and answer as notarytool would, so nothing reaches Apple.
set -eu
cd "$(dirname "$0")/../.."

tmp=$(mktemp -d "${TMPDIR:-/tmp}/livebridge-notarize-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/LiveBridge.app"
: >"$tmp/LiveBridge.dmg"
: >"$tmp/notes.txt"
echo "stub key" >"$tmp/key.p8"
calls="$tmp/calls"

# notarytool answers with $STUB_STATUS ("garbage" for a reply that is not JSON); stapler staple
# fails the first $STUB_STAPLE_FAILS times; spctl prints $STUB_SOURCE as Gatekeeper's source.
cat >"$tmp/bin/xcrun" <<'EOF'
#!/bin/sh
echo "xcrun $*" >>"$STUB_CALLS"
case "$1 $2" in
  "notarytool submit")
    if [ "$STUB_STATUS" = garbage ]; then
      echo "Error: HTTP status code: 401"
    else
      printf '{"id":"00000000-0000-0000-0000-000000000000","status":"%s","message":"done"}\n' \
        "$STUB_STATUS"
    fi
    ;;
  "notarytool log") echo '{"issues":[{"message":"stub issue"}]}' ;;
  "stapler staple")
    failed=$(grep -c "stapler staple" "$STUB_CALLS")
    if [ "$failed" -le "$STUB_STAPLE_FAILS" ]; then
      echo "Could not find base64 encoded ticket in response" >&2
      exit 65
    fi
    ;;
esac
EOF
cat >"$tmp/bin/spctl" <<'EOF'
#!/bin/sh
echo "spctl $*" >>"$STUB_CALLS"
printf 'stub: accepted\n%s\n' "$STUB_SOURCE" >&2
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/bin/sh
echo "sleep $*" >>"$STUB_CALLS"
EOF
chmod +x "$tmp/bin/xcrun" "$tmp/bin/spctl" "$tmp/bin/sleep"

fail=0
staple_fails=0
source_line="source=Notarized Developer ID"
# Runs notarize.sh on $2 with verdict $1 and the credentials in the environment; sets $status.
run() {
  : >"$calls"
  status=0
  PATH="$tmp/bin:$PATH" STUB_CALLS="$calls" STUB_STATUS="$1" \
    STUB_STAPLE_FAILS="$staple_fails" STUB_SOURCE="$source_line" scripts/notarize.sh "$2" \
    >"$tmp/out" 2>&1 || status=$?
}
staples() { grep -c "stapler staple" "$calls" || true; }
called() { grep -q -e "$1" "$calls"; }
expect() { # description, then the condition that must hold
  what=$1
  shift
  if ! "$@"; then
    echo "notarize: $what" >&2
    sed 's/^/  | /' "$tmp/out" "$calls" >&2
    fail=1
  fi
}

export LIVEBRIDGE_NOTARY_KEY="$tmp/key.p8"
export LIVEBRIDGE_NOTARY_KEY_ID=KEYID00000
export LIVEBRIDGE_NOTARY_ISSUER=00000000-0000-0000-0000-000000000000

for name in LIVEBRIDGE_NOTARY_KEY LIVEBRIDGE_NOTARY_KEY_ID LIVEBRIDGE_NOTARY_ISSUER; do
  saved=$(printenv "$name")
  unset "$name"
  run Accepted "$tmp/LiveBridge.dmg"
  expect "without $name it did not exit 2" [ "$status" = 2 ]
  expect "without $name it called xcrun" [ ! -s "$calls" ]
  export "$name=$saved"
done

LIVEBRIDGE_NOTARY_KEY="$tmp/missing.p8"
run Accepted "$tmp/LiveBridge.dmg"
expect "a missing key file did not exit 2" [ "$status" = 2 ]
expect "a missing key file called xcrun" [ ! -s "$calls" ]
LIVEBRIDGE_NOTARY_KEY="$tmp/key.p8"

: >"$tmp/empty.p8"
LIVEBRIDGE_NOTARY_KEY="$tmp/empty.p8"
run Accepted "$tmp/LiveBridge.dmg"
expect "an empty key file did not exit 2" [ "$status" = 2 ]
expect "an empty key file called xcrun" [ ! -s "$calls" ]
LIVEBRIDGE_NOTARY_KEY="$tmp/key.p8"

run Accepted "$tmp/notes.txt"
expect "a .txt did not exit 2" [ "$status" = 2 ]
expect "a .txt called xcrun" [ ! -s "$calls" ]

run Accepted "$tmp/absent.dmg"
expect "a missing image did not exit 2" [ "$status" = 2 ]

run Invalid "$tmp/LiveBridge.dmg"
expect "an Invalid verdict exited 0" [ "$status" != 0 ]
expect "an Invalid verdict did not fetch the log" called "notarytool log"
expect "an Invalid verdict was stapled" eval '! called stapler'

for verdict in garbage "In Progress"; do
  run "$verdict" "$tmp/LiveBridge.dmg"
  expect "a \"$verdict\" reply exited 0" [ "$status" != 0 ]
  expect "a \"$verdict\" reply was stapled" eval '! called stapler'
done

source_line="override=security disabled"
run Accepted "$tmp/LiveBridge.dmg"
expect "Gatekeeper switched off passed as an assessment" [ "$status" != 0 ]
source_line="source=Notarized Developer ID"

staple_fails=2
run Accepted "$tmp/LiveBridge.dmg"
expect "a staple that failed twice and then worked failed" [ "$status" = 0 ]
expect "the staple was not tried three times" [ "$(staples)" = 3 ]
expect "the retries did not wait" called "^sleep "
staple_fails=3
run Accepted "$tmp/LiveBridge.dmg"
expect "a staple that never worked exited 0" [ "$status" != 0 ]
expect "the staple was tried more than three times" [ "$(staples)" = 3 ]
expect "a submission was retried with the staple" [ "$(grep -c 'notarytool submit' "$calls")" = 1 ]
staple_fails=0

run Accepted "$tmp/LiveBridge.dmg"
expect "an accepted image failed" [ "$status" = 0 ]
expect "the image was not submitted itself" called "notarytool submit $tmp/LiveBridge.dmg"
expect "the image was not stapled" called "stapler staple $tmp/LiveBridge.dmg"
expect "the image's ticket was not validated" called "stapler validate $tmp/LiveBridge.dmg"
expect "Gatekeeper did not assess the image" called "spctl --assess --type open"

run Accepted "$tmp/LiveBridge.app"
expect "an accepted app failed" [ "$status" = 0 ]
expect "the app was not submitted as a zip" called "notarytool submit [^ ]*/LiveBridge.zip"
expect "the app was not stapled" called "stapler staple $tmp/LiveBridge.app"
expect "Gatekeeper did not assess the app" called "spctl --assess --type execute"

exit $fail
