#!/usr/bin/env bash
# loop-pilot fleet — fly every unfinished feature at once, with a shared rate-limit brake.
#
# All loops run CONCURRENTLY. When any one of them detects a rate/usage limit in its agent
# output, it writes ~/.loop-pilot/pause (epoch resume time) — every loop checks that file
# before each phase, so the whole fleet pauses at phase boundaries and resumes together
# when the window resets. No loop is killed; nothing is lost.
#
# Usage:
#   fleet.sh start [agent]      launch every feature with runnable work (default: claude)
#
# Concurrency has TWO dimensions now. fleet.sh runs features side by side; each loop also
# runs up to MAX_PARALLEL phases side by side. Total agent processes = features × MAX_PARALLEL.
# fleet.sh start defaults MAX_PARALLEL to 2 (not the runner's own 3) because a fleet is
# already wide; export MAX_PARALLEL yourself to override, e.g. MAX_PARALLEL=1 fleet.sh start.
#   fleet.sh status             pause state + scan of everything + dashboard state
#   fleet.sh pause [minutes]    manual fleet-wide pause (default 60)
#   fleet.sh resume             clear the pause now
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${LOOP_PILOT_STATE:-$HOME/.loop-pilot}"
PAUSE_FILE="$STATE_DIR/pause"
CMD="${1:-status}"; shift || true

pause_line() {
  if [ -f "$PAUSE_FILE" ]; then
    local until now left; until="$(cat "$PAUSE_FILE" 2>/dev/null || echo 0)"; now="$(date +%s)"
    case "$until" in ''|*[!0-9]*) until=0;; esac
    if [ "$now" -lt "$until" ]; then
      left=$(( (until - now) / 60 ))
      echo "⏸  FLEET PAUSED — loops finish their current phase, then wait. Resumes in ~${left}m."
      return
    fi
  fi
  echo "▶  fleet not paused"
}

features() {  # every feature dir under registered repos
  local roots=() line
  if [ -f "$STATE_DIR/repos.txt" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && [ "${line:0:1}" != "#" ] && roots+=("$line")
    done < "$STATE_DIR/repos.txt"
  fi
  [ ${#roots[@]} -eq 0 ] && return 0
  local r
  for r in "${roots[@]}"; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth 6 -path '*/docs/features/*/status.md' -not -path '*/node_modules/*' 2>/dev/null \
      | xargs -n1 dirname 2>/dev/null
  done | sort -u
}

case "$CMD" in
  start)
    AGENT="${1:-claude}"
    export MAX_PARALLEL="${MAX_PARALLEL:-2}"      # per-loop cap; fleet width multiplies it
    launched=0; skipped=0
    while IFS= read -r fdir; do
      [ -n "$fdir" ] || continue
      st="$fdir/status.md"
      total="$(grep -cE '^\| *P[0-9][^ |]* *\|' "$st" 2>/dev/null || echo 0)"
      done_n="$(grep -E '^\| *P[0-9][^ |]* *\|' "$st" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$3); if($3=="done") c++} END{print c+0}')"
      # skip finished
      if [ "$total" -gt 0 ] && [ "$done_n" -eq "$total" ]; then skipped=$((skipped+1)); continue; fi
      # skip already-flying
      if [ -f "$fdir/loop.pid" ] && kill -0 "$(cat "$fdir/loop.pid" 2>/dev/null)" 2>/dev/null; then
        echo "already flying: $(basename "$fdir")"; skipped=$((skipped+1)); continue
      fi
      echo "── launching $(basename "$fdir") ──"
      "$HERE/launch.sh" "$fdir" "$AGENT" | grep -E 'LAUNCHED|UPGRADED|registry|ERROR' | sed 's/^/   /'
      launched=$((launched+1))
      sleep 2   # stagger so agent processes don't all cold-start in the same second
    done < <(features)
    echo
    echo "fleet: launched $launched, skipped $skipped (finished or already flying)"
    echo "phase concurrency: up to $MAX_PARALLEL per loop → at most $((launched * MAX_PARALLEL)) agent processes at once"
    pause_line
    [ -x "$HERE/dash.sh" ] && "$HERE/dash.sh" ensure | sed 's/^/dashboard: /'
    echo "watch everything: $("$HERE/dash.sh" url 2>/dev/null || echo http://localhost:8787)"
    echo "limit behavior:   one loop hits the cap → all pause at phase boundaries → all auto-resume"
    ;;
  status)
    pause_line
    [ -x "$HERE/dash.sh" ] && "$HERE/dash.sh" status | sed 's/^/dashboard: /'
    echo
    "$HERE/scan.sh" 2>/dev/null || true
    ;;
  pause)
    MIN="${1:-60}"
    mkdir -p "$(dirname "$PAUSE_FILE")"
    echo "$(( $(date +%s) + MIN * 60 ))" > "$PAUSE_FILE"
    echo "fleet paused for ${MIN}m — running phases finish, then all loops wait."
    ;;
  resume)
    rm -f "$PAUSE_FILE"
    echo "pause cleared — all loops resume at their next check (≤60s)."
    ;;
  *) echo "usage: fleet.sh start [agent] | status | pause [min] | resume"; exit 1 ;;
esac
