#!/bin/sh
# Builds, installs and removes LiveBridge.app (built from the SwiftPM package in app/).
#
#   scripts/build-app.sh                          debug build: app/.build/app/LiveBridge.app, ad hoc
#   scripts/build-app.sh --run [--fake-mic WAV]   debug build, quit its running copy, open it
#   scripts/build-app.sh --release                release build, signed, installed in
#                                                 ~/Applications and opened; run it again to upgrade
#   scripts/build-app.sh --make-signing-identity  create a self-signed code-signing certificate,
#                                                 so the microphone permission survives upgrades
#   scripts/build-app.sh --uninstall              remove the app and every file it keeps
#
# --fake-mic (debug builds only) plays WAV as the microphone. If CFFIXED_USER_HOME is set, the
# app keeps its files under that directory instead of your home folder.
set -eu
cd "$(dirname "$0")/.."

BUNDLE_ID=io.github.nezhinskiy.livebridge
IDENTITY="LiveBridge Local Signing"
INSTALLED="$HOME/Applications/LiveBridge.app"

usage() {
  sed -n '4,10s/^# \{0,1\}//p' "$0" >&2
  exit 2
}

# Builds configuration $1 and assembles the bundle at $2. Bundle.module looks for the resource
# bundle in Contents/Resources.
assemble() {
  (cd app && swift build -c "$1")
  bin=$(cd app && swift build -c "$1" --show-bin-path)
  rm -rf "$2"
  mkdir -p "$2/Contents/MacOS" "$2/Contents/Resources"
  cp "$bin/LiveBridge" "$2/Contents/MacOS/LiveBridge"
  cp app/Support/Info.plist "$2/Contents/Info.plist"
  cp -R "$bin/LiveBridge_LiveBridge.bundle" "$2/Contents/Resources/"
  cp app/Support/AppIcon.icns "$2/Contents/Resources/"
}

# Signs bundle $1 with identity $2 (`-` is ad hoc), hardened runtime and the entitlements.
sign() {
  codesign --force --sign "$2" --options runtime \
    --entitlements app/Support/LiveBridge.entitlements "$1"
}

has_identity() { security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; }

# Ends the running copy of bundle $1, if any, and waits up to 5 s for it to go.
quit() {
  exe="^$1/Contents/MacOS/LiveBridge( |\$)"
  pkill -f "$exe" 2>/dev/null || return 0
  i=0
  while pgrep -f "$exe" >/dev/null && [ $i -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

debug() {
  app="$PWD/app/.build/app/LiveBridge.app"
  assemble debug "$app"
  sign "$app" -
  echo "built $app"
  [ "${1:-}" = --run ] || return 0
  shift
  quit "$app"
  if [ "${1:-}" = --fake-mic ] && [ -n "${2:-}" ]; then
    set -- --fake-mic "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
  fi
  if [ -n "${CFFIXED_USER_HOME:-}" ]; then
    open -n --env "CFFIXED_USER_HOME=$CFFIXED_USER_HOME" "$app" --args "$@"
  else
    open -n "$app" --args "$@"
  fi
}

release() {
  stage="$PWD/app/.build/release-app/LiveBridge.app"
  assemble release "$stage"
  if has_identity; then
    sign "$stage" "$IDENTITY"
  else
    sign "$stage" -
    echo "note: signed ad hoc, so macOS asks for the microphone again after each upgrade;" \
      "scripts/build-app.sh --make-signing-identity keeps the permission"
  fi
  quit "$INSTALLED"
  mkdir -p "$HOME/Applications"
  rm -rf "$INSTALLED"
  ditto "$stage" "$INSTALLED"
  open "$INSTALLED"
  echo "installed $INSTALLED"
}

make_identity() {
  if has_identity; then
    echo "the signing identity \"$IDENTITY\" already exists"
    return 0
  fi
  printf 'Create the self-signed code-signing certificate "%s" in your login keychain?\n' \
    "$IDENTITY"
  printf 'It never leaves this Mac and signs only what you build. [y/N] '
  read -r answer </dev/tty || answer=
  case "$answer" in
    y | Y | yes) ;;
    *)
      echo "nothing changed"
      return 1
      ;;
  esac
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cat >"$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  pass=$(/usr/bin/openssl rand -hex 16)
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -name "$IDENTITY" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -passout "pass:$pass" -out "$tmp/identity.p12"
  security import "$tmp/identity.p12" -P "$pass" -T /usr/bin/codesign
  echo "created \"$IDENTITY\"; scripts/build-app.sh --release now signs with it"
}

# Removes exactly these paths; the microphone permission is macOS's, so its reset is printed.
uninstall() {
  if [ -x "$INSTALLED/Contents/MacOS/LiveBridge" ]; then
    quit "$INSTALLED"
    "$INSTALLED/Contents/MacOS/LiveBridge" --unregister-login-item || true
  fi
  lib="$HOME/Library"
  for path in "$INSTALLED" "$lib/Application Support/claude-gpt-live-bridge" \
    "$lib/Caches/$BUNDLE_ID" "$lib/WebKit/$BUNDLE_ID" "$lib/HTTPStorages/$BUNDLE_ID" \
    "$lib/HTTPStorages/$BUNDLE_ID.binarycookies" "$lib/Preferences/$BUNDLE_ID.plist"; do
    if [ -e "$path" ]; then
      rm -rf "$path"
      echo "removed $path"
    fi
  done
  echo "To reset the microphone permission too: tccutil reset Microphone $BUNDLE_ID"
  echo "To remove the Claude Code mod: claude plugin uninstall livebridge@claude-gpt-live-bridge"
}

case "${1:-}" in
  "" | --run) debug "$@" ;;
  --release) release ;;
  --make-signing-identity) make_identity ;;
  --uninstall) uninstall ;;
  *) usage ;;
esac
