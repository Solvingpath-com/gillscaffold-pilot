#!/usr/bin/env bash
# loop-pilot waves — what will actually run together, and why.
#
# Reads the same three files the runner reads (prompts.md, plan.md, status.md) and prints
# the dispatch plan BEFORE anything is launched, so preflight can show the owner the shape
# of the run. Independent of the feature's loop.sh version — safe to run on an old scaffold.
#
# Usage:
#   waves.sh <feature-dir>                       print the dispatch plan
#   waves.sh <feature-dir> --set-lane P4 build   add/replace a `> LANE:` line in prompts.md
#   waves.sh <feature-dir> --json                machine-readable (for the dashboard)
#
# Exit: 0 plan printed · 1 bad usage · 2 no wave table (feature will run serially)
set -uo pipefail

FDIR="${1:?usage: waves.sh <feature-dir> [--set-lane <P> <lane>] [--json]}"; FDIR="${FDIR%/}"
MODE="${2:-}"
STATUS="$FDIR/status.md"; PROMPTS="$FDIR/prompts.md"; PLAN="$FDIR/plan.md"
[ -f "$PROMPTS" ] || { echo "ERROR: $PROMPTS missing — scaffolding gap, send them to grillscaffold"; exit 1; }

phases() { grep -E '^\| *P[0-9][^ |]* *\|' "$STATUS" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); print $2}'; }
state()  { grep -E "^\| *$1 *\|" "$STATUS" 2>/dev/null | head -1 | awk -F'|' '{gsub(/ /,"",$3); print $3}'; }
deps()   { grep -E "^\| *$1 *\|" "$STATUS" 2>/dev/null | head -1 | awk -F'|' '{gsub(/ /,"",$4); print $4}'; }
lane_raw() { awk -v h="$1" '$0 ~ "^## "h"([^0-9A-Za-z]|$)" {f=1; next} f && /^## / {exit} f && /^> LANE:/ {sub(/^> LANE:[ ]*/,""); print; exit}' "$PROMPTS"; }
gate_cmd() { awk -v h="$1" '$0 ~ "^## "h"([^0-9A-Za-z]|$)" {f=1; next} f && /^## / {exit} f && /^> GATE:/ {sub(/^> GATE:[ ]*/,""); print; exit}' "$PROMPTS"; }
is_owner() { awk -v h="$1" '$0 ~ "^## "h"([^0-9A-Za-z]|$)" {f=1; next} f && /^## / {exit} f && /^> OWNER:/ {print; exit}' "$PROMPTS" | grep -q .; }

# ── --set-lane ────────────────────────────────────────────────────────────────
if [ "$MODE" = "--set-lane" ]; then
  PH="${3:?usage: waves.sh <feature-dir> --set-lane <phase> <lane>}"
  LANE="${4:?usage: waves.sh <feature-dir> --set-lane <phase> <lane>}"
  grep -qE "^## $PH([^0-9A-Za-z]|$)" "$PROMPTS" || { echo "ERROR: no '## $PH' section in $PROMPTS"; exit 1; }
  cp "$PROMPTS" "$PROMPTS.bak-$(date +%Y%m%d-%H%M%S)"
  python3 - "$PROMPTS" "$PH" "$LANE" <<'PY'
import re,sys
p,ph,lane=sys.argv[1],sys.argv[2],sys.argv[3]
lines=open(p).read().split("\n")
out=[];i=0;done=False
head=re.compile(rf'^## {re.escape(ph)}([^0-9A-Za-z]|$)')
while i < len(lines):
    out.append(lines[i])
    if not done and head.match(lines[i]):
        i+=1; inserted=False
        while i < len(lines) and not lines[i].startswith('## '):
            if lines[i].startswith('> LANE:'):
                out.append(f'> LANE: {lane}'); inserted=True
            else:
                if not inserted and (lines[i].startswith('```') or lines[i].startswith('> GATE:')):
                    out.append(f'> LANE: {lane}'); inserted=True
                out.append(lines[i])
            i+=1
        if not inserted: out.append(f'> LANE: {lane}')
        done=True
        continue
    i+=1
open(p,'w').write("\n".join(out))
PY
  echo "set: $PH → LANE $LANE   (backup kept beside prompts.md)"
  exec "$0" "$FDIR"
fi

# ── wave table ────────────────────────────────────────────────────────────────
parse_waves() {
  awk '
    /^#+ /   { insec = ($0 ~ /Order and parallelism/ || $0 ~ /Concurrency and waves/) ? 1 : 0 }
    insec && /^\| *[0-9]+ *\|/ {
      split($0, c, "|"); w = c[2]; gsub(/[^0-9]/, "", w);
      n = split(c[3], ps, /[^A-Za-z0-9]+/);
      for (i = 1; i <= n; i++) if (ps[i] ~ /^P[0-9]/) print w, ps[i];
    }' "$1"
}
WAVE_MAP=""; WAVE_SRC=""
for f in "$PROMPTS" "$PLAN"; do
  [ -f "$f" ] || continue
  out="$(parse_waves "$f")"
  [ -n "$out" ] && { WAVE_MAP="$out"; WAVE_SRC="$(basename "$f")"; break; }
done
wave_of() { printf '%s\n' "$WAVE_MAP" | awk -v p="$1" '$2==p {print $1; exit}'; }

if [ "$MODE" = "--json" ]; then
  printf '{"source":"%s","waves":{' "${WAVE_SRC:-none}"
  first=1
  for w in $(printf '%s\n' "$WAVE_MAP" | awk '{print $1}' | sort -n -u); do
    [ $first -eq 1 ] || printf ','; first=0
    printf '"%s":[' "$w"
    sep=""
    for p in $(printf '%s\n' "$WAVE_MAP" | awk -v w="$w" '$1==w {print $2}'); do
      printf '%s"%s"' "$sep" "$p"; sep=","
    done
    printf ']'
  done
  printf '}}\n'
  exit 0
fi

echo "DISPATCH PLAN — $(basename "$FDIR")"
if [ -z "$WAVE_MAP" ]; then
  echo "  wave table: NONE FOUND"
  echo "  → every phase will run ALONE (v2 behaviour). To unlock parallel dispatch, add an"
  echo "    'Order and parallelism' table to prompts.md (or 'Concurrency and waves' to"
  echo "    plan.md), or launch with PARALLEL_MODE=deps to dispatch on Depends-on alone."
  exit 2
fi
echo "  wave table: $WAVE_SRC"

WIDEST=1
for w in $(printf '%s\n' "$WAVE_MAP" | awk '{print $1}' | sort -n -u); do
  grp=""; alone=""; seen=""
  for p in $(printf '%s\n' "$WAVE_MAP" | awk -v w="$w" '$1==w {print $2}'); do
    st="$(state "$p")"; ln="$(lane_raw "$p" | xargs 2>/dev/null || true)"
    tag=""; [ -n "$st" ] && [ "$st" != "todo" ] && tag="($st)"
    if is_owner "$p" || [ "$st" = "done" ]; then
      alone="$alone $p$tag"
    else
      case "$ln" in
        solo|exclusive|alone) alone="$alone ${p}[solo]" ;;
        "") grp="$grp $p$tag"; seen="$seen @$p" ;;
        *)  grp="$grp ${p}[$ln]$tag"
            case " $seen " in *" $ln "*) : ;; *) seen="$seen $ln" ;; esac ;;
      esac
    fi
  done
  n="$(printf '%s\n' $seen | grep -c . )"      # lanes collapse: one slot per distinct lane
  [ "$n" -gt "$WIDEST" ] && WIDEST="$n"
  printf '  wave %s: start together →%s%s\n' "$w" "${grp:- (nothing left)}" "${alone:+   · alone:$alone}"
done

# lanes narrow a wave: report the real ceiling per lane
LANES="$(for p in $(phases); do l="$(lane_raw "$p" | xargs 2>/dev/null || true)"; [ -n "$l" ] && echo "$l"; done | sort -u)"
[ -n "$LANES" ] && {
  echo "  lanes in play (at most one phase each at a time):"
  for l in $LANES; do
    printf '    %-18s %s\n' "$l" "$(for p in $(phases); do [ "$(lane_raw "$p" | xargs 2>/dev/null)" = "$l" ] && printf '%s ' "$p"; done)"
  done
}

MISSING=""
for p in $(phases); do [ -z "$(wave_of "$p")" ] && MISSING="$MISSING $p"; done
[ -n "$MISSING" ] && echo "  ⚠ in no wave row (each will run ALONE):$MISSING"

TOTAL="$(phases | grep -c .)"
echo "  ceiling: after lanes, the widest wave can run $WIDEST phase(s) at once out of $TOTAL total —"
echo "    launch with MAX_PARALLEL=$WIDEST or more to use it (default 3)."
exit 0
