#!/usr/bin/env bash
# loop-pilot status — answer one question: is this loop ALIVE, or STOPPED and what did it leave me?
# Usage:
#   status.sh <feature-dir>      report on one feature
#   status.sh                    report on every launched feature in ~/.loop-pilot/repos.txt
set -uo pipefail

now=$(date +%s)
STATE_DIR="${LOOP_PILOT_STATE:-$HOME/.loop-pilot}"

human_age() { local s=$1; if [ "$s" -lt 60 ]; then echo "${s}s"; elif [ "$s" -lt 3600 ]; then echo "$((s/60))m$((s%60))s"; else echo "$((s/3600))h$(((s%3600)/60))m"; fi; }
mtime() { local v; v="$(stat -c %Y "$1" 2>/dev/null)" || v=""; case "$v" in ''|*[!0-9]*) v="$(stat -f %m "$1" 2>/dev/null)";; esac; case "$v" in ''|*[!0-9]*) v=0;; esac; echo "$v"; }
runinfo() { grep -m1 "^$2=" "$1/.runinfo" 2>/dev/null | cut -d= -f2-; }

fleet_pause_line() {
  local pf="$STATE_DIR/pause" u n
  [ -f "$pf" ] || return 0
  u="$(cat "$pf" 2>/dev/null || echo 0)"; n="$(date +%s)"
  case "$u" in ''|*[!0-9]*) return 0;; esac
  [ "$n" -lt "$u" ] && echo "⏸ FLEET PAUSED — resumes in ~$(( (u-n)/60 ))m (rate-limit brake; loops finish their phase, then wait)"
}

report_one() {
  local fdir="$1" feat pidf log pid alive quiet quiet_s st total done_n qa blocked cur inflight
  feat="$(basename "$fdir")"; pidf="$fdir/loop.pid"
  log="$(ls -t "$fdir"/loop-run-*.log 2>/dev/null | head -1)"
  echo "──────────────────────────────────────────────"
  echo "FEATURE: $feat"
  echo "dir:     $fdir"

  pid=""; alive=0
  [ -f "$pidf" ] && pid="$(cat "$pidf" 2>/dev/null)"
  [ -z "$pid" ] && pid="$(runinfo "$fdir" pid)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive=1; fi

  quiet="n/a"; quiet_s=0
  if [ -n "$log" ]; then quiet_s=$(( now - $(mtime "$log") )); quiet="$(human_age "$quiet_s")"; fi

  st="$fdir/status.md"; total=0; done_n=0; qa=0; blocked=0; cur=""; inflight=""
  [ -f "$fdir/.run/inflight" ] && inflight="$(tr -s " " " " < "$fdir/.run/inflight" | sed "s/^ *//; s/ *$//")"
  if [ -f "$st" ]; then
    while IFS= read -r row; do
      local p="${row%%:*}" s="${row#*:}"
      total=$((total+1))
      case "$s" in done) done_n=$((done_n+1));; qa-pending) qa=$((qa+1));; blocked) blocked=$((blocked+1));;
        in-progress) cur="${cur:+$cur, }$p";; esac
    done < <(grep -E '^\| *P[0-9][^ |]* *\|' "$st" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); gsub(/ /,"",$3); print $2":"$3}')
  fi

  local audit result ended qa_items defects
  audit="$(ls -t "$fdir"/audit-*.md 2>/dev/null | head -1)"
  result="$(runinfo "$fdir" result)"; ended="$(runinfo "$fdir" ended)"
  qa_items="$(runinfo "$fdir" qa_items)"; defects="$(runinfo "$fdir" defects)"

  if [ "$alive" -eq 1 ]; then
    local flying nflying=0 _p
    flying="${inflight:-$cur}"
    for _p in $flying; do nflying=$((nflying+1)); done
    if [ "$nflying" -gt 1 ]; then
      echo "VERDICT: ▶ RUNNING (pid $pid) — ${done_n}/${total} done, ${qa} qa-pending, $nflying in flight: $flying"
      echo "         concurrent phases are normal — the wave table sanctioned this pairing."
    else
      echo "VERDICT: ▶ RUNNING (pid $pid) — ${done_n}/${total} done, ${qa} qa-pending${flying:+, now on $flying}"
    fi
    if [ "$quiet_s" -gt 1800 ]; then
      echo "         ⚠ log silent for $quiet — longer than a normal phase. Read the tail below;"
      echo "           if the agent is wedged: kill $pid  then relaunch (it resumes from status.md)."
    else
      echo "         log last moved $quiet ago — silence here is NORMAL, an agent thinks for minutes."
    fi
  elif [ -n "$result" ] && [ -n "$ended" ]; then
    echo "VERDICT: ■ STOPPED — $result. ${qa_items:-?} QA item(s) for you, ${defects:-?} defect(s)."
    [ -f "$fdir/QA.md" ] && echo "         your test list: $fdir/QA.md"
    [ -n "$audit" ]      && echo "         audit report:   $audit"
  elif [ -f "$fdir/.runinfo" ]; then
    echo "VERDICT: ■ EXITED — the loop started but never wrote an ending (crash, kill, or sleep)."
    echo "         Relaunch: it resumes from status.md. Read the log tail below for the cause."
  elif [ -z "$log" ]; then
    echo "VERDICT: ○ NEVER LAUNCHED (no loop-run-*.log in this folder)"
  else
    echo "VERDICT: ■ STOPPED — ${done_n}/${total} done; no .runinfo (pre-v4 runner or a killed run)."
  fi
  [ -n "$log" ] && [ "$alive" -eq 0 ] && echo "         last log activity: $quiet ago"

  if [ -f "$fdir/loop.sh" ]; then
    local tv mp ag
    tv="$(grep -m1 '^# template-version:' "$fdir/loop.sh" | grep -oE '[0-9]+' | head -1)"
    mp="$(runinfo "$fdir" max_parallel)"; ag="$(runinfo "$fdir" agent)"
    if [ -n "$tv" ] && [ "$tv" -ge 4 ] 2>/dev/null; then
      echo "  runner:  template v$tv — A→Z contract${ag:+, last agent $ag}${mp:+, up to $mp phase(s) in flight}"
    else
      echo "  runner:  pre-v4 template — stops for a human. Upgrade before flying: upgrade.sh $fdir"
    fi
  fi
  if [ -f "$fdir/QA.md" ] && [ "$alive" -eq 0 ]; then
    local open_n; open_n="$(grep -c '^- \[ \]\|^  - \[ \]' "$fdir/QA.md" 2>/dev/null || echo 0)"
    echo "  QA.md:   $open_n unticked item(s) — $fdir/QA.md"
  fi
  if [ -f "$st" ]; then echo; echo "  phases:"; grep -E '^\| *P[0-9][^ |]* *\|' "$st" | sed 's/^/    /'; fi
  if [ -n "$log" ]; then
    echo; echo "  log: $log"; echo "  last 8 lines:"; tail -8 "$log" | sed 's/^/    | /'
    echo; echo "  follow it:  tail -f $log"
  fi
  echo
}

fleet_pause_line
if [ $# -ge 1 ]; then report_one "${1%/}"; exit 0; fi

ROOTS=()
if [ -f "$STATE_DIR/repos.txt" ]; then
  while IFS= read -r line; do [ -n "$line" ] && [ "${line:0:1}" != "#" ] && ROOTS+=("$line"); done < "$STATE_DIR/repos.txt"
fi
[ ${#ROOTS[@]} -eq 0 ] && ROOTS=(".")

found=0
for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || continue
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    found=1; report_one "$d"
  done < <(find "$root" -maxdepth 7 \( -name 'loop.pid' -o -name 'loop-run-*.log' -o -name '.runinfo' \) \
           -path '*/docs/features/*' -not -path '*/node_modules/*' 2>/dev/null | xargs -n1 dirname 2>/dev/null | sort -u)
done
[ $found -eq 0 ] && echo "No launched loops found under: ${ROOTS[*]}"
exit 0
