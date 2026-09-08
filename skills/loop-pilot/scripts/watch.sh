#!/usr/bin/env bash
# loop-pilot watch — block until this feature's loop actually stops, then say why.
# Beats `tail -f`: tail goes quiet mid-phase and looks identical to a dead loop.
# Usage: watch.sh <feature-dir> [poll-seconds]
set -uo pipefail

FDIR="${1:?usage: watch.sh <feature-dir> [poll-seconds]}"; FDIR="${FDIR%/}"
POLL="${2:-30}"
PIDF="$FDIR/loop.pid"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PID=""
[ -f "$PIDF" ] && PID="$(cat "$PIDF" 2>/dev/null)"
[ -z "$PID" ] && PID="$(grep -m1 '^pid=' "$FDIR/.runinfo" 2>/dev/null | cut -d= -f2)"
[ -n "$PID" ] || { echo "No live loop recorded in $FDIR — nothing to watch. Run status.sh $FDIR"; exit 1; }

if ! kill -0 "$PID" 2>/dev/null; then
  echo "Loop already stopped."
  "$HERE/status.sh" "$FDIR"
  exit 0
fi

echo "Watching pid $PID (polling every ${POLL}s). Ctrl-C to stop watching — the loop keeps running."
start=$(date +%s)
while kill -0 "$PID" 2>/dev/null; do
  sleep "$POLL"
  cur="$(grep -E '^\| *P[0-9][^ |]* *\|' "$FDIR/status.md" 2>/dev/null \
        | awk -F'|' '{gsub(/ /,"",$2); gsub(/ /,"",$3); if ($3=="in-progress") print $2}' | head -1)"
  el=$(( ($(date +%s) - start) / 60 ))
  printf '\r  alive %sm — %s   ' "$el" "${cur:-between phases}"
done
echo
echo "LOOP STOPPED after $(( ($(date +%s) - start) / 60 ))m — every ending writes QA.md and an audit."

# desktop nudge (macOS first, then Linux) — best effort, never fatal
if command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$(basename "$FDIR") loop stopped\" with title \"loop-pilot\" sound name \"Glass\"" >/dev/null 2>&1
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "loop-pilot" "$(basename "$FDIR") loop stopped" >/dev/null 2>&1
else
  printf '\a'
fi

"$HERE/status.sh" "$FDIR"
