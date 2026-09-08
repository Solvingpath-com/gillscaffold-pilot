# loop.sh template (autonomy v2)

Generate `docs/features/<feature>/loop.sh` (mark it executable). Agent-agnostic: each phase
runs in a fresh headless process (Claude Code, Codex, or Kimi). Fresh OS process per phase =
clean context; nothing leaks between phases.

**Run contract: ONE START, ONE FINISH — now with self-healing.** On top of the v1
route-around contract, this template adds four autonomy mechanisms:

1. **Watchdog** — every phase runs under a timeout (`PHASE_TIMEOUT_SEC`, default 45 min).
   A wedged agent is killed, not waited on forever.
2. **Self-heal retry** — a phase that times out, ends silent, fails its gate, or marks
   itself blocked gets ONE fresh retry (`MAX_RETRIES`) with the failure evidence injected
   into the prompt ("previous attempt ended with: …") before it is routed around.
3. **Gates** — a `> GATE: <shell command>` line in a phase's prompts.md section is a
   deterministic check the LOOP runs after the agent claims done (`tsc --noEmit`, a test
   file, `maestro test flow.yaml`, a preview-channel deploy). Gate fails → the done claim
   is revoked, the row goes blocked, and the retry mechanism fires. Agents don't grade
   their own homework.
4. **Shared rate-limit pause** — if a phase's output shows a rate/usage limit, the row is
   reset to todo (no retry consumed), and a fleet-wide pause file
   (`~/.loop-pilot/pause`, epoch resume time inside) is written. EVERY loop on the
   machine checks it before each phase, so one loop hitting the limit pauses the whole
   fleet at phase boundaries, and all resume automatically when the window resets
   (`LIMIT_BACKOFF_MIN`, default 30).

Endings are unchanged: all done → AUDIT; manual items remain → `handoff.md`. Both endings,
plus routed-around phases and pauses, fire `notify.sh` (Telegram / webhook) if loop-pilot's
notifier is configured — so the owner's phone learns the moment input is needed.

`./loop.sh --preflight` unchanged. Fill `<feature>`, primary repo path, at-keyboard IDs.

---

```bash
#!/usr/bin/env bash
# grillscaffold unattended runner (autonomy v2) — <feature>
# ONE START, ONE FINISH. Fresh agent process per phase; timeout watchdog; one evidence-fed
# retry; deterministic GATE checks; fleet-wide rate-limit pause; notifications at endings.
set -uo pipefail   # no -e — a failing phase must never kill the run

# ── Config ────────────────────────────────────────────────────────────────────
AGENT="${AGENT:-claude}"
PRIMARY_REPO="<primary repo absolute path>"
FEATURE_DIR="$PRIMARY_REPO/docs/features/<feature>"
STATUS="$FEATURE_DIR/status.md"
PROMPTS="$FEATURE_DIR/prompts.md"
HANDOFF="$FEATURE_DIR/handoff.md"
AT_KEYBOARD=(<space-separated at-keyboard phase IDs, e.g. P3>)
MAX_PHASES=30
PHASE_TIMEOUT_SEC="${PHASE_TIMEOUT_SEC:-2700}"     # watchdog per attempt (45 min)
GATE_TIMEOUT_SEC="${GATE_TIMEOUT_SEC:-900}"
MAX_RETRIES="${MAX_RETRIES:-1}"                    # evidence-fed retries per phase
LIMIT_BACKOFF_MIN="${LIMIT_BACKOFF_MIN:-30}"       # pause length on rate/usage limit
PAUSE_FILE="$HOME/.loop-pilot/pause"
LIMIT_RX='rate[ _-]?limit|usage limit|limit (reached|exceeded)|too many requests|resets at|overloaded_error|HTTP 429'
PLOGS="$FEATURE_DIR/logs"; mkdir -p "$PLOGS"

with_timeout() {  # with_timeout <sec> <cmd…> — cmd must be a real binary, not a function
  local t="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$@"
  else "$@"; fi
}

run_agent() {  # $1 = prompt; fresh process under the watchdog, from the primary repo
  cd "$PRIMARY_REPO"
  case "$AGENT" in
    claude) with_timeout "$PHASE_TIMEOUT_SEC" claude -p "$1" ;;
    codex)  with_timeout "$PHASE_TIMEOUT_SEC" codex exec "$1" ;;
    kimi)   with_timeout "$PHASE_TIMEOUT_SEC" kimi -p "$1" ;;
    *) echo "Unknown AGENT '$AGENT'"; exit 1 ;;
  esac
}



# ── status.md helpers ─────────────────────────────────────────────────────────
row()   { grep -E "^\| *$1 *\|" "$STATUS" | head -1; }
state() { row "$1" | awk -F'|' '{gsub(/ /,"",$3); print $3}'; }
deps()  { row "$1" | awk -F'|' '{gsub(/ /,"",$4); print $4}'; }
notes() { row "$1" | awk -F'|' '{n=NF-1; gsub(/^ +| +$/,"",$n); print $n}'; }
phases(){ grep -E '^\| *P[0-9][^ |]* *\|' "$STATUS" | awk -F'|' '{gsub(/ /,"",$2); print $2}'; }

is_at_keyboard() { local k; for k in "${AT_KEYBOARD[@]:-}"; do [ "$1" = "$k" ] && return 0; done; return 1; }

deps_done() {
  local d; d="$(deps "$1")"
  [ "$d" = "—" ] || [ -z "$d" ] && return 0
  local dep; for dep in ${d//,/ }; do [ "$(state "$dep")" = "done" ] || return 1; done
  return 0
}

set_state() {
  python3 - "$STATUS" "$1" "$2" <<'PY'
import re,sys
p,ph,st=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p).read()
s=re.sub(rf'^(\| *{re.escape(ph)} *\| *)[^|]*(\|)',rf'\g<1>{st} \g<2>',s,count=1,flags=re.M)
open(p,'w').write(s)
PY
}

extract_block() { awk -v h="$1" '$0 ~ "^## "h {f=1} f && /^```/ {c++; next} f && c==1 {print} c==2 {exit}' "$PROMPTS"; }
owner_lines()   { awk -v h="$1" '$0 ~ "^## "h {f=1; next} f && /^## / {exit} f && /^> OWNER:/ {sub(/^> OWNER:[ ]*/,""); print "  - " $0}' "$PROMPTS"; }
gate_cmd()      { awk -v h="$1" '$0 ~ "^## "h {f=1; next} f && /^## / {exit} f && /^> GATE:/ {sub(/^> GATE:[ ]*/,""); print; exit}' "$PROMPTS"; }

note() { printf -- "- [loop] %s\n" "$1" >> "$STATUS"; echo "LOOP: $1"; }

notify() {  # notify <title> <body> — best effort, backgrounded, never blocks the run
  local s
  for s in "${LOOP_PILOT_NOTIFY:-}" "$HOME/.claude/skills/loop-pilot/scripts/notify.sh"; do
    [ -n "$s" ] && [ -x "$s" ] && { "$s" "$1" "$2" >/dev/null 2>&1 & return 0; }
  done; return 0
}

# ── fleet pause (shared across every loop on this machine) ────────────────────
wait_if_paused() {
  while [ -f "$PAUSE_FILE" ]; do
    local until now; until="$(cat "$PAUSE_FILE" 2>/dev/null || echo 0)"; now="$(date +%s)"
    case "$until" in ''|*[!0-9]*) until=0;; esac
    if [ "$now" -ge "$until" ]; then rm -f "$PAUSE_FILE"; note "pause expired — resuming"; break; fi
    local left=$(( until - now )); [ "$left" -gt 60 ] && left=60
    sleep "$left"
  done
}

pause_fleet() {  # $1 = minutes; never shortens an existing longer pause
  mkdir -p "$(dirname "$PAUSE_FILE")"
  local until=$(( $(date +%s) + $1 * 60 )) cur=0
  [ -f "$PAUSE_FILE" ] && cur="$(cat "$PAUSE_FILE" 2>/dev/null || echo 0)"
  case "$cur" in ''|*[!0-9]*) cur=0;; esac
  [ "$until" -gt "$cur" ] && echo "$until" > "$PAUSE_FILE"
  note "rate/usage limit detected — fleet paused ${1}m (all loops resume automatically)"
  notify "<feature>: fleet paused" "Rate/usage limit hit. Every loop pauses at its next phase boundary and resumes in ~${1}m."
}

# ── route-around bookkeeping ──────────────────────────────────────────────────
SKIP=" "
skip()      { SKIP="$SKIP$1 "; }
is_skipped(){ case "$SKIP" in *" $1 "*) return 0;; *) return 1;; esac; }

runnable() {
  local ph
  for ph in $(phases); do
    [ "$(state "$ph")" = "todo" ] || continue
    is_at_keyboard "$ph" && continue
    is_skipped "$ph" && continue
    deps_done "$ph" || continue
    echo "$ph"; return
  done
  echo ""
}

all_done() { local ph; for ph in $(phases); do [ "$(state "$ph")" = "done" ] || return 1; done; return 0; }

write_handoff() {
  local ph ready_manual="" fix="" waiting="" n=0
  for ph in $(phases); do
    case "$(state "$ph")" in
      done) continue ;;
      blocked|qa-pending)
        fix="$fix- **$ph** ($(state "$ph")) — $(notes "$ph")\n"; n=$((n+1)) ;;
      todo|in-progress)
        if is_at_keyboard "$ph" && deps_done "$ph"; then
          ready_manual="$ready_manual- **$ph** — run this at the keyboard. Owner checklist:\n$(owner_lines "$ph")\n"; n=$((n+1))
        else
          waiting="$waiting- **$ph** — waiting on: $(deps "$ph")\n"
        fi ;;
    esac
  done
  {
    echo "# Handoff — <feature> ($(date '+%Y-%m-%d %H:%M'))"
    echo
    echo "The unattended run finished: everything that could run without you has run."
    echo "Work the list below, then rerun \`./loop.sh\` — it continues to the audit."
    echo
    echo "## 1. Run these at the keyboard (ready now)"
    [ -n "$ready_manual" ] && printf "%b" "$ready_manual" || echo "_none_"
    echo
    echo "## 2. Fix these (blocked / qa-pending)"
    [ -n "$fix" ] && printf "%b" "$fix" || echo "_none_"
    echo
    echo "## 3. Waiting on the above (no action needed)"
    [ -n "$waiting" ] && printf "%b" "$waiting" || echo "_none_"
  } > "$HANDOFF"
  echo "LOOP: handoff written → $HANDOFF"
  notify "<feature>: HANDOFF ($n item(s))" "Unattended run done — your input is needed. Read: $HANDOFF"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--preflight" ]; then
  echo "PREFLIGHT — <feature>"
  echo "At-keyboard phases (the loop will route around these):"
  if [ -n "${AT_KEYBOARD[*]:-}" ]; then
    for k in "${AT_KEYBOARD[@]}"; do
      echo "- $k (state: $(state "$k"), deps: $(deps "$k")). Owner checklist:"
      owner_lines "$k"
    done
  else
    echo "_none — this run can go start to audit with zero owner input_"
  fi
  echo
  echo "Gates found in prompts.md:"
  for k in $(phases); do g="$(gate_cmd "$k")"; [ -n "$g" ] && echo "- $k: $g"; done
  exit 0
fi

# ── Main loop ─────────────────────────────────────────────────────────────────
for i in $(seq 1 "$MAX_PHASES"); do
  wait_if_paused
  PH="$(runnable)"

  if [ -z "$PH" ]; then
    if all_done; then
      echo "LOOP: all phases done — running AUDIT in a fresh process"
      wait_if_paused
      run_agent "$(extract_block 'AUDIT')"
      echo "LOOP: audit complete — read $FEATURE_DIR/audit-*.md, worst finding first."
      notify "<feature>: COMPLETE" "All phases done, audit written. Read $FEATURE_DIR/audit-*.md"
      exit 0
    fi
    note "run complete: no runnable phase remains — writing handoff for the owner"
    write_handoff
    exit 0
  fi

  BLOCK="$(extract_block "$PH ")"
  if [ -z "$BLOCK" ]; then
    set_state "$PH" "blocked"
    note "routed around $PH: no prompt block found in prompts.md"
    skip "$PH"; continue
  fi

  GATE="$(gate_cmd "$PH")"
  attempt=0; FAILCTX=""
  while :; do
    wait_if_paused
    attempt=$((attempt+1))
    PHLOG="$PLOGS/$PH-attempt$attempt-$(date +%H%M%S).log"

    PROMPT="$BLOCK"
    if [ -n "$FAILCTX" ]; then
      PROMPT="PREVIOUS ATTEMPT AT THIS PHASE FAILED. Evidence from that attempt:
---
$FAILCTX
---
First diagnose what went wrong using the evidence and the current state of the repo,
fix it, then complete the phase per the original instructions below. Update status.md
honestly as always.

$BLOCK"
    fi

    echo "LOOP: phase $PH attempt $attempt → fresh $AGENT process (timeout ${PHASE_TIMEOUT_SEC}s, log: $PHLOG)"
    set_state "$PH" "in-progress"
    run_agent "$PROMPT" > "$PHLOG" 2>&1
    RC=$?
    tail -3 "$PHLOG" | sed 's/^/  agent| /'

    # rate/usage limit: pause everything, retry same phase without consuming a retry
    if grep -qiE "$LIMIT_RX" "$PHLOG"; then
      set_state "$PH" "todo"
      pause_fleet "$LIMIT_BACKOFF_MIN"
      attempt=$((attempt-1))
      continue
    fi

    ST="$(state "$PH")"
    if [ "$ST" = "done" ]; then
      if [ -n "$GATE" ]; then
        GLOG="$PLOGS/$PH-gate-attempt$attempt.log"
        echo "LOOP: $PH gate → $GATE"
        ( cd "$PRIMARY_REPO" && with_timeout "$GATE_TIMEOUT_SEC" bash -c "$GATE" ) > "$GLOG" 2>&1
        if [ $? -ne 0 ]; then
          set_state "$PH" "blocked"
          FAILCTX="Agent marked the phase done, but the gate command failed.
Gate: $GATE
Gate output (tail):
$(tail -20 "$GLOG")"
          note "$PH gate FAILED (attempt $attempt): $GATE — done claim revoked"
        else
          note "$PH done — gate passed: $GATE"
          break
        fi
      else
        echo "LOOP: $PH done (no gate defined)"
        break
      fi
    elif [ "$ST" = "qa-pending" ]; then
      note "routed around $PH: qa-pending — see its Notes cell; dependents will wait"
      notify "<feature>: $PH needs QA" "$(notes "$PH")"
      skip "$PH"; break
    elif [ "$ST" = "in-progress" ]; then
      set_state "$PH" "blocked"
      if [ "$RC" -eq 124 ]; then
        FAILCTX="The previous attempt hit the ${PHASE_TIMEOUT_SEC}s watchdog timeout and was killed.
Agent output (tail):
$(tail -20 "$PHLOG")"
        note "$PH watchdog timeout after ${PHASE_TIMEOUT_SEC}s (attempt $attempt)"
      else
        FAILCTX="The previous attempt ended WITHOUT updating status.md (silent session, exit code $RC).
Agent output (tail):
$(tail -20 "$PHLOG")"
        note "$PH ended silent without updating status.md (attempt $attempt)"
      fi
    else  # blocked by the agent's own hand
      FAILCTX="The previous attempt marked the phase blocked.
Notes cell: $(notes "$PH")
Agent output (tail):
$(tail -20 "$PHLOG")"
      note "$PH self-blocked (attempt $attempt): $(notes "$PH")"
    fi

    # retry or route around
    if [ "$attempt" -le "$MAX_RETRIES" ]; then
      echo "LOOP: retrying $PH with failure evidence (retry $attempt of $MAX_RETRIES)"
      continue
    fi
    note "routed around $PH after $attempt attempt(s) — dependents will wait"
    notify "<feature>: $PH blocked" "Routed around after $attempt attempts. Last note: $(notes "$PH")"
    skip "$PH"; break
  done
done
note "MAX_PHASES reached — writing handoff with whatever remains"
write_handoff
exit 0
```

---

## Writing gates (the `> GATE:` line)

One line per phase in prompts.md, directly under the phase heading, before the fenced
prompt block. The loop runs it from the primary repo after the agent claims done. Examples:

- Type/lint gate (default for any TS phase): `> GATE: npx tsc --noEmit && npx eslint . --max-warnings 0`
- Build gate (Next.js phases): `> GATE: rm -rf .next && npx next build`
- Test gate: `> GATE: npx vitest run src/lessons --reporter=dot`
- **Device-QA replacement (React Native)**: `> GATE: maestro test .maestro/<feature>-flow.yaml`
  — have an early phase GENERATE the Maestro flow file as part of its deliverables, then the
  formerly at-keyboard QA phase becomes an autonomous phase whose gate drives the emulator.
- **Web-QA replacement (Firebase App Hosting / Hosting)**:
  `> GATE: firebase hosting:channel:deploy <feature> --json > /tmp/ch.json && python3 -c "import json;print(json.load(open('/tmp/ch.json'))['result'])"`
  — deploy succeeds = gate passes, and the preview URL lands in the gate log and handoff, so
  human QA becomes "tap this link", not "sit down and run it".
