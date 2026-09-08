#!/usr/bin/env bash
# loop-pilot dash — the dashboard as a service, not a chore.
#
# launch.sh and fleet.sh call `dash.sh ensure` so the browser view is already up by the time
# the first phase starts. Idempotent by design: `ensure` never starts a second server, and
# stopping the dashboard never touches a loop.
#
# Usage:
#   dash.sh ensure [--open]   start it only if nothing is serving the port (what launch uses)
#   dash.sh start  [--open]   same, but says so loudly if it was already up
#   dash.sh status            is it serving? on what port, which pid, since when
#   dash.sh stop              stop the dashboard (loops keep flying)
#   dash.sh restart           stop + ensure (use after upgrading the skill)
#   dash.sh url               print the URL and nothing else
#
# Env:
#   DASHBOARD_PORT=8787            port to serve on
#   LOOP_PILOT_NO_DASHBOARD=1      make `ensure` a no-op (for headless/CI runs)
#   LOOP_PILOT_OPEN_DASHBOARD=1    `ensure` also opens a browser tab
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${DASHBOARD_PORT:-8787}"
STATE="${LOOP_PILOT_STATE:-$HOME/.loop-pilot}"
PIDF="$STATE/dashboard.pid"
LOG="$STATE/dashboard.log"
URL="http://localhost:$PORT"
CMD="${1:-status}"; shift || true
OPEN=0
for a in "$@"; do [ "$a" = "--open" ] && OPEN=1; done
[ "${LOOP_PILOT_OPEN_DASHBOARD:-0}" = "1" ] && OPEN=1
mkdir -p "$STATE"

# Is anything actually answering on the port? This — not the pid file — is the real test:
# the user may have started dashboard.py by hand in another terminal, and starting a second
# one would just fail to bind and confuse everybody.
port_open() {
  python3 - "$PORT" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(); s.settimeout(0.4)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)
PY
}

pid_of() {  # our pid file, only if that process is still alive
  [ -f "$PIDF" ] || return 1
  local p; p="$(cat "$PIDF" 2>/dev/null)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { printf '%s\n' "$p"; return 0; }
  return 1
}

open_browser() {
  if command -v open >/dev/null 2>&1; then open "$URL" >/dev/null 2>&1 &
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL" >/dev/null 2>&1 &
  fi
}

start_it() {
  if [ ! -s "$STATE/repos.txt" ]; then
    echo "not started — no repos registered yet ($STATE/repos.txt is empty)."
    echo "  launch.sh registers a repo automatically; after your first launch this works."
    return 1
  fi
  nohup python3 "$HERE/dashboard.py" --port "$PORT" >> "$LOG" 2>&1 &
  echo $! > "$PIDF"
  local i=0
  while [ $i -lt 25 ]; do
    port_open && { echo "started → $URL  (pid $(cat "$PIDF"), log: $LOG)"; [ "$OPEN" = "1" ] && open_browser; return 0; }
    sleep 0.2; i=$((i+1))
  done
  echo "FAILED to come up on port $PORT within 5s — last lines of $LOG:"
  tail -5 "$LOG" | sed 's/^/    /'
  rm -f "$PIDF"
  return 1
}

case "$CMD" in
  ensure)
    if [ "${LOOP_PILOT_NO_DASHBOARD:-0}" = "1" ]; then echo "skipped (LOOP_PILOT_NO_DASHBOARD=1)"; exit 0; fi
    if port_open; then
      echo "already serving → $URL"
      [ "$OPEN" = "1" ] && open_browser
      exit 0
    fi
    start_it
    ;;
  start)
    if port_open; then echo "already serving → $URL (nothing to do)"; exit 0; fi
    start_it
    ;;
  status)
    if port_open; then
      if p="$(pid_of)"; then echo "▶ serving → $URL (pid $p, started by loop-pilot)"
      else echo "▶ serving → $URL (started outside loop-pilot — stop it where you started it)"; fi
    else
      echo "○ not serving on port $PORT"
    fi
    ;;
  stop)
    if p="$(pid_of)"; then
      kill "$p" 2>/dev/null
      rm -f "$PIDF"
      echo "stopped (pid $p). Loops are unaffected — they never talk to the dashboard."
    elif port_open; then
      echo "something is serving port $PORT but loop-pilot did not start it — stop it in its own terminal."
      exit 1
    else
      echo "not running."
    fi
    ;;
  restart)
    "$0" stop >/dev/null 2>&1
    sleep 0.5
    if [ "$OPEN" = "1" ]; then "$0" ensure --open; else "$0" ensure; fi
    ;;
  url) echo "$URL" ;;
  *) echo "usage: dash.sh ensure|start|status|stop|restart|url [--open]"; exit 1 ;;
esac
