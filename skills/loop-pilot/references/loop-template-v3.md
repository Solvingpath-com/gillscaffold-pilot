# loop.sh template (autonomy v3 — wave parallelism)

Generate `docs/features/<feature>/loop.sh` (mark it executable). Agent-agnostic: each phase
runs in a fresh headless process (Claude Code, Codex, or Kimi). Fresh OS process per phase =
clean context; nothing leaks between phases.

**Run contract: ONE START, ONE FINISH — self-healing, and now concurrent where the plan
says it is safe.** v2's four autonomy mechanisms are unchanged:

1. **Watchdog** — every attempt runs under `PHASE_TIMEOUT_SEC` (default 45 min).
2. **Self-heal retry** — timeout, silent session, self-block, or failed gate buys ONE fresh
   retry (`MAX_RETRIES`) with the failure evidence injected into the prompt.
3. **Gates** — `> GATE: <shell command>` under a phase heading is run BY THE LOOP after the
   agent claims done. Fail → done claim revoked → retry. Agents don't grade their own homework.
4. **Shared rate-limit pause** — limit text in agent output resets the row to todo (no retry
   consumed) and writes `~/.loop-pilot/pause`; every loop on the machine honours it at phase
   boundaries.

**What v3 adds — phase-level parallelism.** v2 ran exactly one phase at a time and ignored
the wave table the grill produced. v3 keeps up to `MAX_PARALLEL` phases in flight, and the
plan decides which ones may share the air:

- **Waves are the authority.** The `| Wave | Run together |` table — from prompts.md's
  "Order and parallelism" section, else plan.md's "Concurrency and waves" — is parsed at
  run time. Two phases may run together only if the table puts them in the **same wave**,
  their `Depends on` phases are all `done`, and their lanes don't collide. A phase the table
  never mentions runs **alone**, so an unannotated feature behaves exactly like v2.
- **Lanes are the exclusion mechanism.** `> LANE: <name>` under a phase heading (same place
  as `> GATE:` and `> OWNER:`) means *at most one phase in this lane runs at a time* — the
  machine-readable form of "only one contract-regenerating phase in flight". `> LANE: solo`
  (or `exclusive`/`alone`) means the phase runs with nothing else beside it. No LANE line =
  no lane constraint.
- **status.md writes are serialized** by a `mkdir` mutex the loop holds for every state
  change and log append, and concurrent agents are told, in their prompt, to touch only
  their own row. Belt and braces: the loop remembers every `done` it confirmed and
  **repairs any row a concurrent session overwrites** — an agent that rewrites the whole
  table from a stale read costs a log line, not a lost phase.
- **Gates hold a second mutex** so two builds never run at once, and a gate that fails while
  siblings were in flight is re-run once after a settle window before the done claim is
  revoked — a concurrent build is a plausible cause of a false red.
- **At-keyboard phases are untouched.** They are still routed around, never dispatched.

`MAX_PARALLEL` defaults to 3 and is env-overridable per run. `PARALLEL_MODE=off` reproduces
v2 exactly (one phase at a time); `PARALLEL_MODE=deps` ignores waves and dispatches anything
whose dependencies are met, lanes still honoured — an escape hatch for features whose wave
table is missing or wrong, and not the default for a reason.

Endings are unchanged: all done → AUDIT; manual items remain → `handoff.md`. Both endings,
plus routed-around phases and pauses, fire `notify.sh` if loop-pilot's notifier is configured.

`./loop.sh --preflight` also prints the dispatch plan (waves, lanes, what runs with what).
Fill `<feature>`, primary repo path, at-keyboard IDs.

**Portability note: this script must run on macOS's stock bash 3.2.** No associative arrays,
no `wait -n`, no `mapfile`, no `${var,,}`. Job reaping is a `kill -0` poll.

---

```bash
#!/usr/bin/env bash
# template-version: 3
# grillscaffold unattended runner (autonomy v3 — wave parallelism) — <feature>
# ONE START, ONE FINISH. Fresh agent process per phase; up to MAX_PARALLEL phases in flight
# when the plan's wave table sanctions it; timeout watchdog; one evidence-fed retry;
# deterministic GATE checks; fleet-wide rate-limit pause; notifications at endings.
set -uo pipefail   # no -e — a failing phase must never kill the run

# ── Config ────────────────────────────────────────────────────────────────────
AGENT="${AGENT:-claude}"
PRIMARY_REPO="<primary repo absolute path>"
FEATURE_DIR="$PRIMARY_REPO/docs/features/<feature>"
STATUS="$FEATURE_DIR/status.md"
PROMPTS="$FEATURE_DIR/prompts.md"
PLAN="$FEATURE_DIR/plan.md"
HANDOFF="$FEATURE_DIR/handoff.md"
AT_KEYBOARD=(<space-separated at-keyboard phase IDs, e.g. P3>)
MAX_PHASES=30
MAX_PARALLEL="${MAX_PARALLEL:-3}"                  # phases in flight at once (1 = v2 behaviour)
PARALLEL_MODE="${PARALLEL_MODE:-waves}"            # waves | deps | off
PHASE_TIMEOUT_SEC="${PHASE_TIMEOUT_SEC:-2700}"     # watchdog per attempt (45 min)
GATE_TIMEOUT_SEC="${GATE_TIMEOUT_SEC:-900}"
GATE_SETTLE_SEC="${GATE_SETTLE_SEC:-20}"           # re-check window for a gate red under concurrency
MAX_RETRIES="${MAX_RETRIES:-1}"                    # evidence-fed retries per phase
LIMIT_BACKOFF_MIN="${LIMIT_BACKOFF_MIN:-30}"       # pause length on rate/usage limit
POLL_SEC="${POLL_SEC:-5}"                          # scheduler tick
PAUSE_FILE="$HOME/.loop-pilot/pause"
LIMIT_RX='rate[ _-]?limit|usage limit|limit (reached|exceeded)|too many requests|resets at|overloaded_error|HTTP 429'
PLOGS="$FEATURE_DIR/logs"; mkdir -p "$PLOGS"
RUNDIR="$FEATURE_DIR/.run"; rm -rf "$RUNDIR"; mkdir -p "$RUNDIR"
STATUS_LOCK="$FEATURE_DIR/.status.lock"
GATE_LOCK="$FEATURE_DIR/.gate.lock"
rmdir "$STATUS_LOCK" "$GATE_LOCK" 2>/dev/null   # a previous run killed mid-write leaves these

[ "$PARALLEL_MODE" = "off" ] && MAX_PARALLEL=1
case "$MAX_PARALLEL" in ''|*[!0-9]*) MAX_PARALLEL=1;; esac
[ "$MAX_PARALLEL" -lt 1 ] && MAX_PARALLEL=1

with_timeout() {  # with_timeout <sec> <cmd…> — cmd must be a real binary, not a function
  local t="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$@"
  else "$@"; fi
}

run_agent() {  # $1 = prompt; fresh process under the watchdog, from the primary repo
  cd "$PRIMARY_REPO" || { echo "cannot cd to $PRIMARY_REPO"; return 1; }
  case "$AGENT" in
    claude) with_timeout "$PHASE_TIMEOUT_SEC" claude -p "$1" ;;
    codex)  with_timeout "$PHASE_TIMEOUT_SEC" codex exec "$1" ;;
    kimi)   with_timeout "$PHASE_TIMEOUT_SEC" kimi -p "$1" ;;
    *) echo "Unknown AGENT '$AGENT'"; exit 1 ;;
  esac
}

# ── mutexes (mkdir is atomic everywhere; flock is not on macOS) ────────────────
lock_acquire() {  # lock_acquire <lockdir> [max-wait-sec]
  local ld="$1" cap="${2:-120}" waited=0
  until mkdir "$ld" 2>/dev/null; do
    sleep 1; waited=$((waited+1))
    if [ "$waited" -ge "$cap" ]; then rm -rf "$ld"; waited=0; fi   # break a stale lock
  done
}
lock_release() { rmdir "$1" 2>/dev/null || true; }

# ── status.md helpers (reads are lock-free; every WRITE takes the mutex) ───────
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
  lock_acquire "$STATUS_LOCK"
  python3 - "$STATUS" "$1" "$2" <<'PY'
import re,sys
p,ph,st=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p).read()
s=re.sub(rf'^(\| *{re.escape(ph)} *\| *)[^|]*(\|)',rf'\g<1>{st} \g<2>',s,count=1,flags=re.M)
open(p,'w').write(s)
PY
  lock_release "$STATUS_LOCK"
}

note() {
  lock_acquire "$STATUS_LOCK"
  printf -- "- [loop] %s\n" "$1" >> "$STATUS"
  lock_release "$STATUS_LOCK"
  printf 'LOOP: %s\n' "$1"
}

say() { printf '%s\n' "$*"; }   # one write() per line keeps concurrent output un-interleaved

# ── prompts.md section readers ────────────────────────────────────────────────
# Heading match is boundary-anchored so "P1" never matches "## P12 — …".
extract_block() { awk -v h="$1" '$0 ~ "^## "h"([^0-9A-Za-z]|$)" {f=1} f && /^```/ {c++; next} f && c==1 {print} c==2 {exit}' "$PROMPTS"; }
owner_lines()   { awk -v h="$1" '$0 ~ "^## "h"([^0-9A-Za-z]|$)" {f=1; next} f && /^## / {exit} f && /^> OWNER:/ {sub(/^> OWNER:[ ]*/,""); print "  - " $0}' "$PROMPTS"; }
gate_cmd()      { awk -v h="$1" '$0 ~ "^## "h"([^0-9A-Za-z]|$)" {f=1; next} f && /^## / {exit} f && /^> GATE:/ {sub(/^> GATE:[ ]*/,""); print; exit}' "$PROMPTS"; }
lane_raw()      { awk -v h="$1" '$0 ~ "^## "h"([^0-9A-Za-z]|$)" {f=1; next} f && /^## / {exit} f && /^> LANE:/ {sub(/^> LANE:[ ]*/,""); print; exit}' "$PROMPTS"; }

lane_of() {  # a phase with no LANE line gets a private lane, i.e. no constraint
  local l; l="$(lane_raw "$1" | tr -d '`' | xargs 2>/dev/null || true)"
  if [ -n "$l" ]; then printf '%s\n' "$l"; else printf '@%s\n' "$1"; fi
}
is_solo() { case "$(lane_of "$1")" in solo|exclusive|alone) return 0;; *) return 1;; esac; }

# ── wave table (the plan's authority on what may run together) ────────────────
# Parses `| 2 | P3, P4 |` rows under "Order and parallelism" (prompts.md) or
# "Concurrency and waves" (plan.md). First file that yields rows wins.
WAVE_MAP=""; WAVE_SRC="none"
parse_waves() {
  awk '
    /^#+ /   { insec = ($0 ~ /Order and parallelism/ || $0 ~ /Concurrency and waves/) ? 1 : 0 }
    insec && /^\| *[0-9]+ *\|/ {
      split($0, c, "|"); w = c[2]; gsub(/[^0-9]/, "", w);
      n = split(c[3], ps, /[^A-Za-z0-9]+/);
      for (i = 1; i <= n; i++) if (ps[i] ~ /^P[0-9]/) print w, ps[i];
    }' "$1"
}
load_waves() {
  local f out
  for f in "$PROMPTS" "$PLAN"; do
    [ -f "$f" ] || continue
    out="$(parse_waves "$f")"
    if [ -n "$out" ]; then WAVE_MAP="$out"; WAVE_SRC="$f"; return 0; fi
  done
  return 1
}
wave_of() { printf '%s\n' "$WAVE_MAP" | awk -v p="$1" '$2==p {print $1; exit}'; }

# every other phase the wave table puts alongside $1 and that is not finished — the set a
# concurrent agent should be told about, whether or not it happens to be running yet
wave_mates() {
  local w p out=""
  w="$(wave_of "$1")"; [ -z "$w" ] && return 0
  for p in $(printf '%s\n' "$WAVE_MAP" | awk -v w="$w" '$1==w {print $2}'); do
    [ "$p" = "$1" ] && continue
    is_at_keyboard "$p" && continue
    [ "$(state "$p")" = "done" ] && continue
    out="$out $p"
  done
  printf '%s\n' "$out" | xargs 2>/dev/null || true
}

# ── notifications ─────────────────────────────────────────────────────────────
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

# ── route-around bookkeeping (file-backed: workers are subshells) ──────────────
skip()      { : > "$RUNDIR/skip.$1"; }
is_skipped(){ [ -f "$RUNDIR/skip.$1" ]; }

# ── clobber repair ────────────────────────────────────────────────────────────
# The loop's own status.md writes are serialized, but the AGENTS' are not — nothing can
# lock a headless session. A session that rewrites the whole table from a stale read can
# revert a sibling's finished row. So the loop remembers every `done` IT confirmed and
# restores any row that regresses. Only the loop ever marks a phase confirmed-done.
confirm_done() { : > "$RUNDIR/done.$1"; }
repair_rows() {
  local f ph bad
  for f in "$RUNDIR"/done.*; do
    [ -e "$f" ] || continue
    ph="$(basename "$f")"; ph="${ph#done.}"
    bad="$(state "$ph")"
    if [ "$bad" != "done" ]; then
      set_state "$ph" "done"
      note "repaired $ph: row read '$bad' but this loop confirmed it done — a concurrent session overwrote it"
    fi
  done
}

# ── in-flight bookkeeping (parent only) ───────────────────────────────────────
RUNNING=""                                     # "P2:1234 P5:1240"
running_phases() { local e; for e in $RUNNING; do printf '%s\n' "${e%%:*}"; done; }
running_count()  { local e n=0; for e in $RUNNING; do n=$((n+1)); done; printf '%s\n' "$n"; }
is_running()     { local p; for p in $(running_phases); do [ "$p" = "$1" ] && return 0; done; return 1; }
publish_inflight() { running_phases | tr '\n' ' ' > "$RUNDIR/inflight"; }

# siblings of $1 currently in flight (portable: BSD sed has no \b)
sibs_of() {
  tr ' ' '\n' < "$RUNDIR/inflight" 2>/dev/null | grep -v "^$1$" | grep -v '^$' \
    | tr '\n' ' ' | xargs 2>/dev/null || true
}

# a backgrounded child is FINISHED when it left a result file, or when its pid is gone /
# a zombie. kill -0 alone is not enough: an un-waited child stays visible as a zombie.
child_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" in Z*) return 1;; esac
  return 0
}

lane_free() {
  local want p; want="$(lane_of "$1")"
  for p in $(running_phases); do
    [ "$(lane_of "$p")" = "$want" ] && return 1
    is_solo "$p" && return 1
  done
  is_solo "$1" && [ -n "$RUNNING" ] && return 1
  return 0
}

wave_ok() {  # may $1 join whatever is already in flight?
  [ -z "$RUNNING" ] && return 0
  [ "$PARALLEL_MODE" = "deps" ] && return 0
  local cw rw p
  cw="$(wave_of "$1")"
  [ -z "$cw" ] && return 1                      # not in the table → runs alone
  for p in $(running_phases); do
    rw="$(wave_of "$p")"
    [ "$cw" = "$rw" ] || return 1
  done
  return 0
}

next_dispatchable() {  # first phase eligible to start right now, or ""
  local ph
  for ph in $(phases); do
    [ "$(state "$ph")" = "todo" ] || continue
    is_at_keyboard "$ph" && continue
    is_skipped "$ph" && continue
    is_running "$ph" && continue
    deps_done "$ph" || continue
    lane_free "$ph" || continue
    wave_ok "$ph" || continue
    printf '%s\n' "$ph"; return
  done
  printf '\n'
}

any_future_work() {  # is there a non-at-keyboard phase that could still run later?
  local ph
  for ph in $(phases); do
    [ "$(state "$ph")" = "todo" ] || continue
    is_at_keyboard "$ph" && continue
    is_skipped "$ph" && continue
    return 0
  done
  return 1
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
  say "LOOP: handoff written → $HANDOFF"
  notify "<feature>: HANDOFF ($n item(s))" "Unattended run done — your input is needed. Read: $HANDOFF"
}

load_waves || true

# ── Preflight ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--preflight" ] || [ "${1:-}" = "--plan" ]; then
  echo "PREFLIGHT — <feature>"
  echo "Parallelism: MAX_PARALLEL=$MAX_PARALLEL, mode=$PARALLEL_MODE, wave table: $WAVE_SRC"
  if [ -n "$WAVE_MAP" ]; then
    echo "Dispatch groups (phases on one line start together, slots permitting):"
    for w in $(printf '%s\n' "$WAVE_MAP" | awk '{print $1}' | sort -n -u); do
      grp=""; solo=""
      for p in $(printf '%s\n' "$WAVE_MAP" | awk -v w="$w" '$1==w {print $2}'); do
        if is_at_keyboard "$p"; then solo="$solo $p(at-keyboard)"
        elif is_solo "$p";      then solo="$solo $p(solo)"
        else
          ln="$(lane_raw "$p" | xargs 2>/dev/null || true)"
          if [ -n "$ln" ]; then grp="$grp ${p}[$ln]"; else grp="$grp $p"; fi
        fi
      done
      echo "  wave $w:${grp:- —}${solo:+   run alone:$solo}"
    done
    for p in $(phases); do
      [ -z "$(wave_of "$p")" ] && echo "  ⚠ $p is in no wave row — it will run ALONE"
    done
  else
    echo "  no wave table found — every phase runs alone (v2 behaviour)."
    echo "  Add an 'Order and parallelism' table to prompts.md (or 'Concurrency and waves'"
    echo "  to plan.md) to unlock parallel dispatch, or run with PARALLEL_MODE=deps."
  fi
  echo
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

# ── Phase worker — the whole lifecycle of ONE phase, run in the background ─────
# Writes its outcome to $RUNDIR/<PH>.result: done | skipped
phase_worker() {
  local PH="$1" BLOCK GATE attempt RC ST PHLOG GLOG PROMPT SIBS FAILCTX

  BLOCK="$(extract_block "$PH")"
  if [ -z "$BLOCK" ]; then
    set_state "$PH" "blocked"
    note "routed around $PH: no prompt block found in prompts.md"
    echo "skipped" > "$RUNDIR/$PH.result"; return
  fi

  GATE="$(gate_cmd "$PH")"
  attempt=0; FAILCTX=""
  while :; do
    wait_if_paused
    attempt=$((attempt+1))
    PHLOG="$PLOGS/$PH-attempt$attempt-$(date +%H%M%S).log"

    PROMPT="$BLOCK"
    if [ "$MAX_PARALLEL" -gt 1 ]; then
      SIBS="$(printf '%s %s' "$(sibs_of "$PH")" "$(wave_mates "$PH")" \
              | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | xargs 2>/dev/null || true)"
    else
      SIBS=""
    fi
    if [ -n "$SIBS" ]; then
      PROMPT="CONCURRENT RUN NOTICE. Other phases are executing RIGHT NOW in this same repo,
in their own sessions, or are about to be: $SIBS. The plan's wave table says your phase
and theirs do not touch the same files. Therefore:
- Work ONLY on the files this phase owns. If a file you need is being rewritten under you,
  do not fight it — mark your row blocked in status.md with the detail and stop.
- In status.md, edit ONLY the $PH row and APPEND to the Progress log. Never rewrite,
  reformat, re-sort or renumber the phase table, and never touch another phase's row.
- Do not run repo-wide builds or formatters (they will collide with the other sessions);
  your gate runs after you, serialized by the loop.

$PROMPT"
    fi
    if [ -n "$FAILCTX" ]; then
      PROMPT="PREVIOUS ATTEMPT AT THIS PHASE FAILED. Evidence from that attempt:
---
$FAILCTX
---
First diagnose what went wrong using the evidence and the current state of the repo,
fix it, then complete the phase per the original instructions below. Update status.md
honestly as always.

$PROMPT"
    fi

    say "LOOP: phase $PH attempt $attempt → fresh $AGENT process (timeout ${PHASE_TIMEOUT_SEC}s, log: $PHLOG)"
    set_state "$PH" "in-progress"
    run_agent "$PROMPT" > "$PHLOG" 2>&1
    RC=$?
    tail -3 "$PHLOG" | sed "s/^/  $PH agent| /"

    # rate/usage limit: pause everything, retry the same phase without consuming a retry
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
        say "LOOP: $PH waiting for the gate lock → $GATE"
        lock_acquire "$GATE_LOCK" 1800
        ( cd "$PRIMARY_REPO" && with_timeout "$GATE_TIMEOUT_SEC" bash -c "$GATE" ) > "$GLOG" 2>&1
        RC=$?
        # A red gate while siblings were mid-flight is plausibly collateral: settle, retry once.
        if [ "$RC" -ne 0 ] && [ -n "$(sibs_of "$PH")" ]; then
          say "LOOP: $PH gate red with siblings in flight — settling ${GATE_SETTLE_SEC}s and re-running once"
          sleep "$GATE_SETTLE_SEC"
          ( cd "$PRIMARY_REPO" && with_timeout "$GATE_TIMEOUT_SEC" bash -c "$GATE" ) > "$GLOG" 2>&1
          RC=$?
        fi
        lock_release "$GATE_LOCK"
        if [ "$RC" -ne 0 ]; then
          set_state "$PH" "blocked"
          FAILCTX="Agent marked the phase done, but the gate command failed.
Gate: $GATE
Gate output (tail):
$(tail -20 "$GLOG")"
          note "$PH gate FAILED (attempt $attempt): $GATE — done claim revoked"
        else
          confirm_done "$PH"
          note "$PH done — gate passed: $GATE"
          echo "done" > "$RUNDIR/$PH.result"; return
        fi
      else
        confirm_done "$PH"
        say "LOOP: $PH done (no gate defined)"
        echo "done" > "$RUNDIR/$PH.result"; return
      fi
    elif [ "$ST" = "qa-pending" ]; then
      note "routed around $PH: qa-pending — see its Notes cell; dependents will wait"
      notify "<feature>: $PH needs QA" "$(notes "$PH")"
      echo "skipped" > "$RUNDIR/$PH.result"; return
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

    if [ "$attempt" -le "$MAX_RETRIES" ]; then
      say "LOOP: retrying $PH with failure evidence (retry $attempt of $MAX_RETRIES)"
      continue
    fi
    note "routed around $PH after $attempt attempt(s) — dependents will wait"
    notify "<feature>: $PH blocked" "Routed around after $attempt attempts. Last note: $(notes "$PH")"
    echo "skipped" > "$RUNDIR/$PH.result"; return
  done
}

# ── Scheduler ─────────────────────────────────────────────────────────────────
say "LOOP: <feature> — agent=$AGENT, up to $MAX_PARALLEL phase(s) in flight (mode=$PARALLEL_MODE, waves from ${WAVE_SRC##*/})"

reap() {  # collect finished workers and apply their outcome
  local e ph pid still=""
  for e in $RUNNING; do
    ph="${e%%:*}"; pid="${e##*:}"
    if [ ! -f "$RUNDIR/$ph.result" ] && child_alive "$pid"; then
      still="$still $e"
      continue
    fi
    wait "$pid" 2>/dev/null
    case "$(cat "$RUNDIR/$ph.result" 2>/dev/null)" in
      done) say "LOOP: $ph finished — done" ;;
      *)    skip "$ph"; say "LOOP: $ph finished — routed around" ;;
    esac
  done
  RUNNING="$(printf '%s' "$still" | xargs 2>/dev/null || true)"
  publish_inflight
}

DISPATCHED=0
while :; do
  repair_rows                              # undo any stale-read clobber before deciding
  # 1. fill free slots
  while [ "$(running_count)" -lt "$MAX_PARALLEL" ] && [ "$DISPATCHED" -lt "$MAX_PHASES" ]; do
    wait_if_paused
    PH="$(next_dispatchable)"
    [ -z "$PH" ] && break
    set_state "$PH" "in-progress"          # claim the row before backgrounding
    rm -f "$RUNDIR/$PH.result"
    ( trap '[ -f "$RUNDIR/'"$PH"'.result" ] || echo skipped > "$RUNDIR/'"$PH"'.result" ' EXIT
      phase_worker "$PH" ) &
    RUNNING="$(printf '%s %s:%s' "$RUNNING" "$PH" "$!" | xargs)"
    DISPATCHED=$((DISPATCHED+1))
    publish_inflight
    say "LOOP: dispatched $PH  (in flight: $(running_phases | tr '\n' ' '))"
    sleep 1                                 # stagger starts; avoids two agents booting in lockstep
  done

  # 2. nothing running and nothing dispatchable → the run is over
  if [ -z "$RUNNING" ]; then
    repair_rows
    if all_done; then
      say "LOOP: all phases done — running AUDIT in a fresh process"
      wait_if_paused
      run_agent "$(extract_block 'AUDIT')"
      say "LOOP: audit complete — read $FEATURE_DIR/audit-*.md, worst finding first."
      notify "<feature>: COMPLETE" "All phases done, audit written. Read $FEATURE_DIR/audit-*.md"
      rm -rf "$RUNDIR"; exit 0
    fi
    if [ "$DISPATCHED" -ge "$MAX_PHASES" ] && any_future_work; then
      note "MAX_PHASES reached — writing handoff with whatever remains"
    else
      note "run complete: no runnable phase remains — writing handoff for the owner"
    fi
    write_handoff
    rm -rf "$RUNDIR"; exit 0
  fi

  # 3. wait for something to finish, then loop and refill
  sleep "$POLL_SEC"
  reap
  repair_rows
done
```

---

## Writing the wave table (what unlocks parallelism)

grillscaffold already emits one in prompts.md under `## Order and parallelism` and in
plan.md under `## Concurrency and waves`. The runner reads prompts.md first. Only the
numeric rows matter:

```markdown
| Wave | Run together |
|---|---|
| 1 | P0 |
| 2 | P2, P3 |
| 3 | P4 |
```

- Phases on the same row start together when their `Depends on` phases are `done`.
- A phase **not listed in any row runs alone** — that is the safe default, and it means a
  half-filled table degrades gracefully instead of guessing.
- Waves are barriers: nothing from wave 3 starts while a wave-2 phase is still in flight,
  even if its dependencies are technically met. That is what the grill meant by a wave, and
  it is what keeps "P4 rebuilds the generated client" from landing under P3's feet.
- `PARALLEL_MODE=deps` drops the barrier and dispatches purely on `Depends on` + lanes. Use
  it when you trust the dependency column more than the wave table.

## Writing lanes (the `> LANE:` line)

One line per phase in prompts.md, next to `> GATE:` / `> OWNER:`. A lane is a mutex name:

- `> LANE: generated-client` on every phase that regenerates the API client — the wave table
  may put them together, the lane guarantees only one runs at a time.
- `> LANE: migrations` on phases writing schema migrations.
- `> LANE: solo` — this phase runs with nothing else in flight (also `exclusive` / `alone`).
- No LANE line — no constraint beyond waves and dependencies.

Lanes are the machine-readable form of the plan's blocking rules ("only one
contract-regenerating phase in flight"). Write the rule as prose in plan.md for humans and
as a LANE line for the runner.

## Writing gates (the `> GATE:` line)

Unchanged from v2, with one concurrency note: **gates are serialized** across the feature by
a mutex, and a gate that goes red while sibling phases are in flight is re-run once after
`GATE_SETTLE_SEC` before the done claim is revoked. Write gates that check *this phase's*
work; a repo-wide `rm -rf .next && next build` in a wave with three phases will be slow and
flaky no matter what the loop does — prefer a targeted gate in parallel waves and keep the
full build for a wave of its own.

- Type/lint gate (default for any TS phase): `> GATE: npx tsc --noEmit && npx eslint . --max-warnings 0`
- Build gate (Next.js phases): `> GATE: rm -rf .next && npx next build`
- Test gate: `> GATE: npx vitest run src/lessons --reporter=dot`
- **Device-QA replacement (React Native)**: `> GATE: maestro test .maestro/<feature>-flow.yaml`
  — have an early phase GENERATE the Maestro flow file as part of its deliverables, then the
  formerly at-keyboard QA phase becomes an autonomous phase whose gate drives the emulator.
  Emulator gates are single-tenant: give every Maestro phase `> LANE: emulator`.
- **Web-QA replacement (Firebase App Hosting / Hosting)**:
  `> GATE: firebase hosting:channel:deploy <feature> --json > /tmp/ch.json && python3 -c "import json;print(json.load(open('/tmp/ch.json'))['result'])"`
  — deploy succeeds = gate passes, and the preview URL lands in the gate log and handoff, so
  human QA becomes "tap this link", not "sit down and run it". Preview-channel deploys share
  a channel name: `> LANE: preview-deploy`.
