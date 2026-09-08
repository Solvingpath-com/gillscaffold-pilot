# loop.sh template

Generate `docs/features/<feature>/loop.sh` (mark it executable: `chmod +x`). This is the
default unattended runner and it is **agent-agnostic**: each phase runs in a fresh headless
process of whichever agent the owner configures — Claude Code, Codex, or Kimi. A fresh OS
process per phase is the strongest possible guarantee that every phase starts with clean
context; nothing from phase N can leak into phase N+1.

**The run contract is ONE START, ONE FINISH.** Nothing that needs a human is fatal:
at-keyboard phases, failed gates, blocked or qa-pending rows, silent sessions, and missing
prompt blocks are all **routed around** — recorded, and the loop moves on to the next
runnable phase. Dependents of a routed-around phase simply wait (their deps aren't `done`,
so `runnable()` never selects them), while every independent branch keeps running. The run
ends in exactly one of two ways:

1. **All phases done** → the AUDIT runs automatically in a fresh process. Read the report.
2. **Manual items remain** → `handoff.md` is written: a categorized owner TODO (run these
   at the keyboard + their checklists / fix these / waiting on the above). The owner works
   the list, reruns `./loop.sh`, and the loop continues from where it left off — repeat
   until path 1.

`./loop.sh --preflight` prints every at-keyboard phase with its `> OWNER:` checklist
**before anything runs**, so front-loadable prep happens upfront instead of surfacing as a
surprise mid-run.

Safety is preserved by the state machine, not by stopping the world: a phase that fails,
stalls, or ends silent is marked `blocked`/`qa-pending` and nothing that depends on it will
ever run — but nothing that *doesn't* depend on it is held hostage either. With no commits,
the per-phase patches remain the rollback boundaries.

Fill the placeholders (`<feature>`, primary repo path, the at-keyboard phase IDs) from the
grill. Keep the script's logic exactly as below.

Note in prompts.md next to the script: the owner should verify the headless command for
their agent version (`claude -p`, `codex exec`, `kimi -p` or equivalent) and their
permission/approval settings for unattended runs before starting one.

---

```bash
#!/usr/bin/env bash
# grillscaffold unattended runner — <feature>
# Contract: ONE START, ONE FINISH. Runs every runnable phase in a FRESH agent process,
# routes around anything needing a human, then either runs the AUDIT (all done) or
# writes handoff.md (manual items remain). Rerun after handoff work; it continues.
# Keep the machine awake (macOS: `caffeinate -dimsu` in a spare terminal).
set -uo pipefail   # NOTE: no -e — a failing phase must never kill the run

# ── Config ────────────────────────────────────────────────────────────────────
AGENT="${AGENT:-claude}"              # claude | codex | kimi
PRIMARY_REPO="<primary repo absolute path>"
FEATURE_DIR="$PRIMARY_REPO/docs/features/<feature>"
STATUS="$FEATURE_DIR/status.md"
PROMPTS="$FEATURE_DIR/prompts.md"
HANDOFF="$FEATURE_DIR/handoff.md"
AT_KEYBOARD=(<space-separated at-keyboard phase IDs, e.g. P3>)  # loop never runs these
MAX_PHASES=30                          # hard safety valve

run_agent() {  # $1 = prompt text; runs from the primary repo, fresh process
  cd "$PRIMARY_REPO"
  case "$AGENT" in
    claude) claude -p "$1" ;;          # adjust permission flags to your settings
    codex)  codex exec "$1" ;;
    kimi)   kimi -p "$1" ;;            # verify your kimi version's headless flag
    *) echo "Unknown AGENT '$AGENT'"; exit 1 ;;
  esac
}

# ── Helpers ───────────────────────────────────────────────────────────────────
row()   { grep -E "^\| *$1 *\|" "$STATUS" | head -1; }
state() { row "$1" | awk -F'|' '{gsub(/ /,"",$3); print $3}'; }
deps()  { row "$1" | awk -F'|' '{gsub(/ /,"",$4); print $4}'; }
notes() { row "$1" | awk -F'|' '{n=NF-1; gsub(/^ +| +$/,"",$n); print $n}'; }
phases(){ grep -E '^\| *P[0-9][^ |]* *\|' "$STATUS" | awk -F'|' '{gsub(/ /,"",$2); print $2}'; }  # P+digit: never matches the header word "Phase"

is_at_keyboard() { local k; for k in "${AT_KEYBOARD[@]:-}"; do [ "$1" = "$k" ] && return 0; done; return 1; }

deps_done() {  # all deps of $1 are done?
  local d; d="$(deps "$1")"
  [ "$d" = "—" ] || [ -z "$d" ] && return 0
  local dep; for dep in ${d//,/ }; do [ "$(state "$dep")" = "done" ] || return 1; done
  return 0
}

set_state() {  # set_state <phase> <new-state> — edits only the State cell
  python3 - "$STATUS" "$1" "$2" <<'PY'
import re,sys
p,ph,st=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p).read()
s=re.sub(rf'^(\| *{re.escape(ph)} *\| *)[^|]*(\|)',rf'\g<1>{st} \g<2>',s,count=1,flags=re.M)
open(p,'w').write(s)
PY
}

extract_block() {  # extract_block "<heading regex>" — first fenced block after the heading
  awk -v h="$1" '$0 ~ "^## "h {f=1} f && /^```/ {c++; next} f && c==1 {print} c==2 {exit}' "$PROMPTS"
}

owner_lines() {  # "> OWNER:" checklist lines in a phase's prompts.md section
  awk -v h="$1" '$0 ~ "^## "h {f=1; next} f && /^## / {exit} f && /^> OWNER:/ {sub(/^> OWNER:[ ]*/,""); print "  - " $0}' "$PROMPTS"
}

note() { printf -- "- [loop] %s\n" "$1" >> "$STATUS"; echo "LOOP: $1"; }

# SKIP holds phases routed around THIS run (space-separated) — so we don't retry them
SKIP=" "
skip()      { SKIP="$SKIP$1 "; }
is_skipped(){ case "$SKIP" in *" $1 "*) return 0;; *) return 1;; esac; }

runnable() {  # first todo phase with all deps done, not at-keyboard, not skipped this run
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

all_done() {
  local ph
  for ph in $(phases); do [ "$(state "$ph")" = "done" ] || return 1; done
  return 0
}

write_handoff() {
  local ph ready_manual="" fix="" waiting=""
  for ph in $(phases); do
    case "$(state "$ph")" in
      done) continue ;;
      blocked|qa-pending)
        fix="$fix- **$ph** ($(state "$ph")) — $(notes "$ph")\n" ;;
      todo|in-progress)
        if is_at_keyboard "$ph" && deps_done "$ph"; then
          ready_manual="$ready_manual- **$ph** — run this at the keyboard. Owner checklist:\n$(owner_lines "$ph")\n"
        else
          waiting="$waiting- **$ph** — waiting on: $(deps "$ph")\n" ;
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
  echo "Anything front-loadable above? Do it NOW, mark the phase done in status.md,"
  echo "and the unattended run will cover everything else in one pass."
  exit 0
fi

# ── Main loop ─────────────────────────────────────────────────────────────────
for i in $(seq 1 "$MAX_PHASES"); do
  PH="$(runnable)"

  if [ -z "$PH" ]; then
    if all_done; then
      echo "LOOP: all phases done — running AUDIT in a fresh process"
      run_agent "$(extract_block 'AUDIT')"
      echo "LOOP: audit complete — read $FEATURE_DIR/audit-*.md, worst finding first."
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

  echo "LOOP: phase $PH → fresh $AGENT process"
  set_state "$PH" "in-progress"
  run_agent "$BLOCK" || true            # judge by status.md, not exit code

  case "$(state "$PH")" in
    done)
      ls "$PRIMARY_REPO/.patches/$PH-"* >/dev/null 2>&1 || note "warning: $PH done but no patch file found"
      echo "LOOP: $PH done" ;;
    in-progress)
      set_state "$PH" "blocked"
      note "routed around $PH: session ended without updating status.md — never build on a silent half-done phase"
      skip "$PH" ;;
    qa-pending|blocked)
      note "routed around $PH: state=$(state "$PH") — see its Notes cell; dependents will wait"
      skip "$PH" ;;
  esac
done
note "MAX_PHASES reached — writing handoff with whatever remains"
write_handoff
exit 0
```
