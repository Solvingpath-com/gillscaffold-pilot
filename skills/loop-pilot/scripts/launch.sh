#!/usr/bin/env bash
# loop-pilot launch — start a loop detached, with log + pid tracking.
# Usage: launch.sh <feature-dir> [agent]     e.g. launch.sh /path/repo/docs/features/x codex
# Env:   MAX_PARALLEL=<n>        phases in flight at once (default 3, 1 = serial)
#        PARALLEL_MODE=waves|deps|off
#        AT_KEYBOARD_MODE=attempt|defer   STRICT_DEPS=0|1   FORCE_FORWARD=0|1
set -uo pipefail

FDIR="${1:?usage: launch.sh <feature-dir> [agent]}"; FDIR="${FDIR%/}"
AGENT="${2:-${AGENT:-claude}}"
LOOP="$FDIR/loop.sh"
LOG="$FDIR/loop-run-$(date +%Y%m%d-%H%M%S).log"
PIDF="$FDIR/loop.pid"
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$LOOP" ] || { echo "ERROR: $LOOP missing — scaffolding gap, run grillscaffold"; exit 1; }

# a phase must never launch another orchestration
if [ -n "${LOOP_PILOT_NESTED:-}" ]; then
  echo "ERROR: refusing to launch — this shell is inside an agent phase of a loop-pilot run."
  echo "Finish this phase; the parent loop schedules the rest."
  exit 3
fi

# ── the agent must be installed and authenticated, or every phase fails ───────
if [ -x "$SDIR/agents.sh" ]; then
  if ! "$SDIR/agents.sh" "$AGENT" > /tmp/lp-agent.$$ 2>&1; then
    cat /tmp/lp-agent.$$; rm -f /tmp/lp-agent.$$
    echo "ERROR: $AGENT is not ready. Fix the above, then relaunch."
    exit 1
  fi
  cat /tmp/lp-agent.$$; rm -f /tmp/lp-agent.$$
fi

# ── auto-upgrade: never fly an old-contract runner ───────────────────────────
if [ -x "$SDIR/upgrade.sh" ]; then
  "$SDIR/upgrade.sh" "$FDIR" --check >/dev/null 2>&1
  case $? in
    0) : ;;                                   # CURRENT
    3) echo "loop.sh predates the current template — upgrading in place (backup kept)…"
       "$SDIR/upgrade.sh" "$FDIR" || { echo "ERROR: auto-upgrade failed; not launching an old-contract loop."; exit 1; } ;;
    *) : ;;
  esac
fi
[ -x "$LOOP" ] || chmod +x "$LOOP"

# ── refuse a double start (pid file OR the runner's own .runinfo) ─────────────
live=""
[ -f "$PIDF" ] && live="$(cat "$PIDF" 2>/dev/null)"
if [ -z "$live" ] && [ -f "$FDIR/.runinfo" ] && ! grep -q '^ended=' "$FDIR/.runinfo" 2>/dev/null; then
  live="$(grep '^pid=' "$FDIR/.runinfo" | cut -d= -f2)"
fi
if [ -n "$live" ] && kill -0 "$live" 2>/dev/null; then
  echo "ERROR: a loop is already running for this feature (pid $live)."
  echo "Watch it: tail -f $(ls -t "$FDIR"/loop-run-*.log 2>/dev/null | head -1)"
  exit 1
fi

# show what will run together before it does
if [ -x "$SDIR/waves.sh" ]; then "$SDIR/waves.sh" "$FDIR" | sed 's/^/  /'; fi

AGENT="$AGENT" nohup "$LOOP" > "$LOG" 2>&1 &
PID=$!
echo "$PID" > "$PIDF"

# register the repo so the dashboard/scan always see this run
REPO_ABS="$(cd "$FDIR/../../.." 2>/dev/null && pwd)"
if [ -n "$REPO_ABS" ] && [ -x "$SDIR/repos.sh" ]; then "$SDIR/repos.sh" add "$REPO_ABS" | sed 's/^/registry: /'; fi

# bring up the dashboard if it isn't already (idempotent; LOOP_PILOT_NO_DASHBOARD=1 opts out)
if [ -x "$SDIR/dash.sh" ] && [ -z "${LOOP_PILOT_NO_DASHBOARD:-}" ]; then "$SDIR/dash.sh" ensure | sed 's/^/dashboard: /'; fi

echo "LAUNCHED — agent=$AGENT pid=$PID max-parallel=${MAX_PARALLEL:-3} mode=${PARALLEL_MODE:-waves} at-keyboard=${AT_KEYBOARD_MODE:-attempt}"
echo "log:    $LOG"
echo
echo "It is running NOW, and it will not stop to ask you anything. Watch it, or walk away:"
echo "  watch everything      $("$SDIR/dash.sh" url 2>/dev/null || echo http://localhost:8787)"
echo "  am I still running?   $SDIR/status.sh $FDIR"
echo "  tell me when it ends  $SDIR/watch.sh  $FDIR      (blocks, pings you, prints why it stopped)"
echo "  stop it               kill $PID                  (safe: rerun resumes from status.md)"
echo
echo "Do NOT judge liveness from 'tail -f' going quiet — a single phase can sit silent for"
echo "10-20 minutes while the agent works. status.sh reads the pid, not the noise. With"
echo "parallel dispatch the log interleaves phases; each phase also has its own file in logs/."
echo
echo "Every ending writes the same two things: an AUDIT report and QA.md, your tickable test list."
echo "  COMPLETE    every phase done or qa-pending — QA.md is what is left for you to verify"
echo "  INCOMPLETE  the loop recorded defects it could not clear — QA.md section 2 names them"
echo "  EXITED      the process died without finishing (crash, kill, machine sleep) — read the log tail"
