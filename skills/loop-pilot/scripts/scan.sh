#!/usr/bin/env bash
# loop-pilot scan — find every feature and report what it needs from you.
# Usage:
#   scan.sh <repo-root> [<repo-root> ...]     scan given repos
#   scan.sh                                    scan roots listed in ~/.loop-pilot/repos.txt
#
# Verdicts:
#   RUNNING      a loop process is alive right now
#   QA-READY     finished, nothing broken — QA.md is waiting for your eyes
#   NEEDS-FIX    finished with defects the loop could not clear (QA.md section 2)
#   FINISHED     every phase done and gate-verified, nothing left
#   RESUMABLE    partial progress, no live loop — relaunch to continue
#   NOT-STARTED  scaffolded, never flown
set -uo pipefail
STATE_DIR="${LOOP_PILOT_STATE:-$HOME/.loop-pilot}"

ROOTS=("$@")
if [ ${#ROOTS[@]} -eq 0 ] && [ -f "$STATE_DIR/repos.txt" ]; then
  while IFS= read -r line; do [ -n "$line" ] && [ "${line:0:1}" != "#" ] && ROOTS+=("$line"); done < "$STATE_DIR/repos.txt"
fi
[ ${#ROOTS[@]} -eq 0 ] && { echo "No repo roots given and no $STATE_DIR/repos.txt"; exit 1; }

found=0
for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || { echo "!! missing root: $root"; continue; }
  while IFS= read -r status; do
    found=1
    fdir="$(dirname "$status")"; feat="$(basename "$fdir")"
    total=0; done_n=0; todo=0; inprog=0; blocked=0; qa=0
    while IFS= read -r ph_state; do
      st="${ph_state#*:}"; total=$((total+1))
      case "$st" in
        done) done_n=$((done_n+1));; todo) todo=$((todo+1));; in-progress) inprog=$((inprog+1));;
        blocked) blocked=$((blocked+1));; qa-pending) qa=$((qa+1));;
      esac
    done < <(grep -E '^\| *P[0-9][^ |]* *\|' "$status" | awk -F'|' '{gsub(/ /,"",$2); gsub(/ /,"",$3); print $2":"$3}')
    [ $total -eq 0 ] && continue

    pid=""; alive=0
    [ -f "$fdir/loop.pid" ] && pid="$(cat "$fdir/loop.pid" 2>/dev/null)"
    [ -z "$pid" ] && pid="$(grep -m1 '^pid=' "$fdir/.runinfo" 2>/dev/null | cut -d= -f2)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1
    result="$(grep -m1 '^result=' "$fdir/.runinfo" 2>/dev/null | cut -d= -f2)"
    open_qa=0
    [ -f "$fdir/QA.md" ] && open_qa="$(grep -c '\[ \]' "$fdir/QA.md" 2>/dev/null || echo 0)"

    if [ $alive -eq 1 ]; then verdict="RUNNING"
    elif [ "$result" = INCOMPLETE ]; then verdict="NEEDS-FIX"
    elif [ "$result" = COMPLETE ] && [ "$open_qa" -gt 0 ]; then verdict="QA-READY"
    elif [ $done_n -eq $total ]; then verdict="FINISHED"
    elif [ $blocked -gt 0 ] || [ $qa -gt 0 ] || [ $inprog -gt 0 ]; then verdict="NEEDS-FIX"
    elif [ $done_n -gt 0 ]; then verdict="RESUMABLE"
    else verdict="NOT-STARTED"; fi

    qafile=""; [ -f "$fdir/QA.md" ] && qafile=" QA.md($open_qa open)"
    audit=""; ls "$fdir"/audit-*.md >/dev/null 2>&1 && audit=" audit✓"
    last="$(grep -E '^- ' "$status" | tail -1 | cut -c1-100)"
    echo "[$verdict] $feat — $done_n/$total done (todo:$todo in-progress:$inprog blocked:$blocked qa-pending:$qa)$qafile$audit"
    echo "    dir:  $fdir"
    [ -n "$last" ] && echo "    last: $last"
    case "$verdict" in
      QA-READY)  echo "    next: work the list → $fdir/QA.md" ;;
      NEEDS-FIX) echo "    next: read QA.md section 2, fix or reset those rows, then relaunch" ;;
      RESUMABLE) echo "    next: launch.sh $fdir" ;;
    esac
  done < <(find "$root" -maxdepth 6 -path '*/docs/features/*/status.md' -not -path '*/node_modules/*' 2>/dev/null)
done
[ $found -eq 0 ] && echo "No features found under: ${ROOTS[*]}"
exit 0
