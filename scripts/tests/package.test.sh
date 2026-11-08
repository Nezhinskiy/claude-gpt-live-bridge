#!/bin/sh
# `build-app.sh --package` with LIVEBRIDGE_SIGN_IDENTITY signs the app and the disk image with
# that identity, the app with hardened runtime, a secure timestamp and the microphone
# entitlement, as notarization needs. A throwaway self-signed identity in a scratch keychain
# stands in for the Developer ID, so the login keychain and its search list are left alone. The
# timestamp comes from Apple's server, so this needs the network.
set -eu
cd "$(dirname "$0")/../.."

tmp=$(mktemp -d "${TMPDIR:-/tmp}/livebridge-package-test.XXXXXX")
keychain="$tmp/signing.keychain-db"
mnt="$tmp/mnt"
cleanup() {
  hdiutil detach -quiet "$mnt" 2>/dev/null || true
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

name="LiveBridge Package Test"
cat >"$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$tmp/cert.cnf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name "$name" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -passout pass:test -out "$tmp/id.p12"
security create-keychain -p test "$keychain"
security unlock-keychain -p test "$keychain"
security import "$tmp/id.p12" -k "$keychain" -P test -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k test "$keychain" >/dev/null
hash=$(security find-identity -p codesigning "$keychain" | awk '$1 == "1)" { print $2; exit }')

LIVEBRIDGE_SIGN_IDENTITY="$hash" LIVEBRIDGE_SIGN_KEYCHAIN="$keychain" \
  LIVEBRIDGE_DIST="$tmp/dist" scripts/build-app.sh --package >"$tmp/log" 2>&1 || {
  cat "$tmp/log" >&2
  echo "--package with an identity failed" >&2
  exit 1
}

fail=0
check() { # description, then the command that must succeed
  what=$1
  shift
  if ! "$@" >/dev/null 2>&1; then
    echo "package: $what" >&2
    fail=1
  fi
}
signed_by_identity() { codesign -dvvv "$1" 2>&1 | grep -qx "Authority=$name"; }
has_runtime() { codesign -dvvv "$1" 2>&1 | grep -q '^CodeDirectory .*flags=.*(runtime)'; }
has_timestamp() { codesign -dvvv "$1" 2>&1 | grep -q '^Timestamp='; }
has_microphone() {
  codesign -d --entitlements - --xml "$1" 2>/dev/null |
    grep -q 'com.apple.security.device.audio-input'
}

image="$tmp/dist/LiveBridge.dmg"
check "the image is missing" test -f "$image"
check "the image is not signed by the identity" signed_by_identity "$image"
check "the image has no secure timestamp" has_timestamp "$image"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$image"
app="$mnt/LiveBridge.app"
check "the app in the image is not signed by the identity" signed_by_identity "$app"
check "the app has no hardened runtime" has_runtime "$app"
check "the app has no secure timestamp" has_timestamp "$app"
check "the app lacks the microphone entitlement" has_microphone "$app"
check "the app fails codesign --verify --deep --strict" \
  codesign --verify --deep --strict "$app"
check "the image has no Applications link" test -L "$mnt/Applications"

exit $fail
