#!/bin/sh
# The end-to-end smoke test: the debug app with a spoken WAV as its microphone, the real codex
# on your ChatGPT login, and a fake Claude Code session (app/Tests/Smoke/fake-session.mjs)
# over the wire. It opens two short realtime sessions, about a minute and a half of voice in all.
#
#   scripts/smoke.sh        SMOKE_DIR=<dir> keeps the scratch files there (default: a new
#                           directory under /tmp; the socket path must stay within 103 bytes)
#
# Passes when, within 150 s: the request produced exactly one handoff and the small talk none,
# the result arrived while the line still waited for it and the voice said it before the small
# talk, that line closed before the small talk opened another, the realtime session was open for
# less than 90 s in all, and the call ended back in `listening`.
set -eu
cd "$(dirname "$0")/.."

dir=${SMOKE_DIR:-$(mktemp -d /tmp/livebridge-smoke.XXXXXX)}
home="$dir/home"
data="$home/Library/Application Support/LiveBridge"
app="$PWD/app/.build/app/LiveBridge.app"
mkdir -p "$home"

# 6 s of silence, the request, 50 s of silence, small talk, then silence to the end.
say -o "$dir/fake-mic.wav" --file-format=WAVE --data-format=LEI16@24000 \
  "[[slnc 6000]] Please list the files in this folder. [[slnc 50000]]
   Thanks! By the way, how is your day going? [[slnc 75000]]"

CFFIXED_USER_HOME="$home" scripts/build-app.sh --run --fake-mic "$dir/fake-mic.wav" >/dev/null
trap 'pkill -f "^$app/Contents/MacOS/LiveBridge( |\$)" || true' EXIT
i=0
until [ -S "$data/run/bridge.sock" ]; do
  i=$((i + 1))
  [ $i -le 100 ] || { echo "smoke: the app did not open its socket" >&2; exit 1; }
  sleep 0.2
done

status=0
node app/Tests/Smoke/fake-session.mjs "$data/run/bridge.sock" 150 || status=$?
echo "conversation:"
node -e 'const { conversations } = JSON.parse(require("fs").readFileSync(process.argv[1]))
  for (const c of Object.values(conversations)) for (const l of c.lines)
    console.log(`  ${l.speaker}: ${l.text}`)' "$data/continuity.json" || true
[ $status = 0 ] && echo "smoke: PASS" || echo "smoke: FAIL"
exit $status
