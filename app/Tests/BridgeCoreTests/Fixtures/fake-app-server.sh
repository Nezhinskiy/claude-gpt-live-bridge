#!/bin/sh
# A stand-in for `codex` in tests; tests copy it as `codex` into a directory with canned replies.
#   codex features list      prints features.txt
#   codex app-server ...     reads one JSON-RPC message per line and, for method a/b with id N,
#                            answers {"id":N,"result":<a_b.json>} when a_b.json exists, then
#                            prints a_b.after when it exists. Every line read goes to
#                            received.log, the arguments to argv.log, and a child `sleep`'s pid
#                            to child.pid (the process-group test kills it through the group).
dir=$(dirname "$0")
if [ "$1" = features ]; then
  cat "$dir/features.txt"
  exit 0
fi
printf '%s\n' "$*" >"$dir/argv.log"
sleep 300 </dev/null >/dev/null 2>&1 &
echo $! >"$dir/child.pid"
while IFS= read -r line; do
  printf '%s\n' "$line" >>"$dir/received.log"
  id=$(printf '%s' "$line" | sed -n 's/^{"id":\([0-9][0-9]*\),.*/\1/p')
  method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p' | tr / _)
  if [ -n "$id" ] && [ -f "$dir/$method.json" ]; then
    printf '{"id":%s,"result":%s}\n' "$id" "$(cat "$dir/$method.json")"
  fi
  if [ -n "$method" ] && [ -f "$dir/$method.after" ]; then cat "$dir/$method.after"; fi
done
