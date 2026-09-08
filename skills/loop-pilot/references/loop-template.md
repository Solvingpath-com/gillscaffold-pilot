# loop.sh template (template v5 — A→Z contract, cross-agent adapters)

Generate `docs/features/<feature>/loop.sh` (mark it executable). **Agent-agnostic**: each phase
runs in a fresh headless process of whichever coding agent the owner configures (`AGENT=claude`,
`AGENT=codex`, `AGENT=kimi`). A fresh OS process per phase is the strongest possible guarantee of
clean context: nothing from phase N leaks into phase N+1, no matter which agent runs it.

**One orchestration contract, thin agent adapters.** Everything in this script is shared across
agents — scheduling, waves, lanes, gates, retries, the rate-limit brake, clobber repair, the
forward sweep, the AUDIT, `QA.md`, `.runinfo` — except one clearly delimited section,
`Agent adapters`. An adapter is responsible for exactly five things: the CLI invocation, prompt
transport (stdin), the working directory, workspace/write permissions, and the extra repository
roots. Nothing else may be agent-specific. `AGENT=claude ./loop.sh` and `AGENT=codex ./loop.sh`
therefore have identical semantics.

**Run contract (v4, unchanged): A → Z, the run does not stop for a human.**

- `qa-pending` is a **completion** state: it satisfies dependents (unless `STRICT_DEPS=1`) and
  becomes a line in `QA.md`.
- At-keyboard phases are **attempted** (`AT_KEYBOARD_MODE=attempt`, default) — alone, with a
  supervised-phase notice, ending `qa-pending` with the human steps in Notes. `AT_KEYBOARD_MODE=defer`
  routes around them instead. Only a `> HUMAN-ONLY: <reason>` line under a phase heading in
  prompts.md stops the loop attempting a phase.
- Phases stranded behind something that never completed are swept forward once with a
  degraded-dependency notice (`FORCE_FORWARD=1`, default; `0` opts out).
- Deterministic `> GATE:` checks are run **by the loop**, never trusted to the agent. A gate that
  fails after its retry is a recorded defect, not an exit.
- Every run ends the same way: the AUDIT runs in a fresh process, `QA.md` is written (four
  sections: verify these · defects the loop could not clear · only you can do these · done and
  gate-verified), `.runinfo` records COMPLETE or INCOMPLETE, and the notifier fires.
- Never commits, pushes, deploys, or touches anything marked `> HUMAN-ONLY:`.

**Portability: this script must run on macOS's stock bash 3.2.** No associative arrays, no
`wait -n`, no `mapfile`, no `${var,,}`, no `local -n`. Job reaping is a `kill -0` poll. Empty
arrays are always guarded with `${#arr[@]}` before expansion.

Fill the four placeholders (`<feature>`, primary repo path, extra repo paths, at-keyboard IDs) at
scaffold time; `loop-pilot/scripts/upgrade.sh` recovers them from an older `loop.sh`, plan.md and
prompts.md when regenerating. Keep the script's logic exactly as below — the contract lives here.

---

```bash
#!/usr/bin/env bash
# template-version: 5
# grillscaffold / loop-pilot unattended runner — <feature>
# Contract v4 (A→Z): fresh agent process per phase · wave parallelism up to MAX_PARALLEL ·
# qa-pending completes · at-keyboard attempted, HUMAN-ONLY never · forward sweep · watchdog ·
# evidence-fed retry · loop-owned GATE checks · fleet-wide rate-limit pause · AUDIT + QA.md at
# every ending. Agent-specific behaviour lives ONLY in the "Agent adapters" section.
set -uo pipefail   # no -e — a failing phase must never kill the run

# ── Config (rendered by grillscaffold / loop-pilot upgrade.sh) ─────────────────
AGENT="${AGENT:-claude}"                           # claude | codex | kimi
FEATURE="<feature>"
PRIMARY_REPO="<primary repo absolute path>"
EXTRA_REPOS=(<extra repo absolute paths, single-quoted, space-separated, or nothing>)
FEATURE_DIR="$PRIMARY_REPO/docs/features/$FEATURE"
AT_KEYBOARD=(<space-separated at-keyboard phase IDs, e.g. P3>)
STATUS="$FEATURE_DIR/status.md"
PROMPTS="$FEATURE_DIR/prompts.md"
PLAN="$FEATURE_DIR/plan.md"
QA_FILE="$FEATURE_DIR/QA.md"
RUNINFO="$FEATURE_DIR/.runinfo"
MAX_PHASES=30
MAX_PARALLEL="${MAX_PARALLEL:-3}"                  # phases in flight at once
PARALLEL_MODE="${PARALLEL_MODE:-waves}"            # waves | deps | off
STRICT_DEPS="${STRICT_DEPS:-0}"                    # 1 = only `done` satisfies a dependency
AT_KEYBOARD_MODE="${AT_KEYBOARD_MODE:-attempt}"    # attempt | defer
FORCE_FORWARD="${FORCE_FORWARD:-1}"                # 1 = sweep stranded phases forward once
PHASE_TIMEOUT_SEC="${PHASE_TIMEOUT_SEC:-2700}"     # watchdog per attempt (45 min)
GATE_TIMEOUT_SEC="${GATE_TIMEOUT_SEC:-900}"
GATE_SETTLE_SEC="${GATE_SETTLE_SEC:-20}"           # re-check window for a gate red under concurrency
MAX_RETRIES="${MAX_RETRIES:-1}"                    # evidence-fed retries per phase
LIMIT_BACKOFF_MIN="${LIMIT_BACKOFF_MIN:-30}"       # pause length on rate/usage limit
POLL_SEC="${POLL_SEC:-5}"                          # scheduler tick
LOOP_EPHEMERAL="${LOOP_EPHEMERAL:-0}"              # 1 = agent sessions are not persisted to disk
PAUSE_FILE="${LOOP_PILOT_STATE:-$HOME/.loop-pilot}/pause"
LIMIT_RX='rate[ _-]?limit|usage limit|limit (reached|exceeded)|too many requests|resets at|overloaded_error|HTTP 429'
PLOGS="$FEATURE_DIR/logs"
RUNDIR="$FEATURE_DIR/.run"
STATUS_LOCK="$FEATURE_DIR/.status.lock"
GATE_LOCK="$FEATURE_DIR/.gate.lock"

# LOOP_EXTRA_REPOS (newline-separated absolute paths) overrides the rendered list for one run.
if [ -n "${LOOP_EXTRA_REPOS:-}" ]; then
  EXTRA_REPOS=()
  while IFS= read -r _r; do [ -n "$_r" ] && EXTRA_REPOS+=("$_r"); done <<EOF
$LOOP_EXTRA_REPOS
EOF
fi

[ "$PARALLEL_MODE" = "off" ] && MAX_PARALLEL=1
case "$MAX_PARALLEL" in ''|*[!0-9]*) MAX_PARALLEL=1;; esac
[ "$MAX_PARALLEL" -lt 1 ] && MAX_PARALLEL=1

say() { printf '%s\n' "$*"; }   # one write() per line keeps concurrent output un-interleaved

# ── Agent adapters ──────────────────────────────────────────────────────────────
# The ONLY agent-specific code in this runner. Contract for adapter_<agent> <mode>:
#   * set AGENT_ARGV to the exact argv of ONE fresh agent process (no shell string)
#   * set AGENT_STDIN=1 when the prompt is delivered on stdin (preferred), 0 when the
#     adapter embedded $PROMPT in AGENT_ARGV itself
#   * the process runs from $PRIMARY_REPO with write access to it and to every EXTRA_REPOS
#     entry, must never wait for interactive approval, and must never widen beyond that.
# <mode> is `phase` or `audit`; the audit is read-only BY INSTRUCTION (it still needs to
# run gates and write audit-<date>.md), adapters may narrow further but must not widen.
AGENT_ARGV=(); AGENT_STDIN=1; AGENT_NOTE=""
_ver_ge() {  # _ver_ge <have> <want> — dotted numeric compare, bash 3.2 safe
  awk -v a="$1" -v b="$2" 'BEGIN{n=split(a,x,".");m=split(b,y,".");for(i=1;i<=(n>m?n:m);i++){p=(i<=n?x[i]+0:0);q=(i<=m?y[i]+0:0);if(p>q){exit 0};if(p<q){exit 1}};exit 0}'
}

adapter_claude() {  # Claude Code: `claude -p`, prompt on stdin, acceptEdits + Bash, extra repos via --add-dir
  local mode="$1" r
  AGENT_ARGV=(claude -p --permission-mode "${CLAUDE_PERMISSION_MODE:-acceptEdits}")
  if [ -n "${CLAUDE_ALLOWED_TOOLS-Bash}" ]; then AGENT_ARGV+=(--allowedTools "${CLAUDE_ALLOWED_TOOLS-Bash}"); fi
  # tool-level enforcement of the no-commit/no-push rule, on top of the prompt's own rule
  if [ -n "${CLAUDE_DISALLOWED_TOOLS-Bash(git commit *),Bash(git commit),Bash(git push *),Bash(git push)}" ]; then
    AGENT_ARGV+=(--disallowedTools "${CLAUDE_DISALLOWED_TOOLS-Bash(git commit *),Bash(git commit),Bash(git push *),Bash(git push)}")
  fi
  if [ "${#EXTRA_REPOS[@]}" -gt 0 ]; then for r in "${EXTRA_REPOS[@]}"; do AGENT_ARGV+=(--add-dir "$r"); done; fi
  case "${CLAUDE_PERMISSION_PROMPTS:-auto}" in   # --permission-prompts none needs Claude Code ≥ 2.1.259
    none) AGENT_ARGV+=(--permission-prompts none) ;;
    auto) [ -n "${CLAUDE_VERSION:-}" ] && _ver_ge "$CLAUDE_VERSION" 2.1.259 && AGENT_ARGV+=(--permission-prompts none) ;;
  esac
  [ "$LOOP_EPHEMERAL" = 1 ] && AGENT_ARGV+=(--no-session-persistence)
  [ -n "${CLAUDE_MODEL:-}" ] && AGENT_ARGV+=(--model "$CLAUDE_MODEL")
  [ -n "${CLAUDE_MAX_TURNS:-}" ] && AGENT_ARGV+=(--max-turns "$CLAUDE_MAX_TURNS")
  [ "$mode" = "audit" ] && AGENT_ARGV+=(--append-system-prompt "This is a READ-ONLY audit pass: never edit source, never commit, never deploy; the only file you may write is the audit report named in the prompt.")
  # shellcheck disable=SC2206
  [ -n "${AGENT_EXTRA_ARGS:-}" ] && AGENT_ARGV+=(${AGENT_EXTRA_ARGS})
  AGENT_STDIN=1; AGENT_NOTE="prompt on stdin · permission-mode ${CLAUDE_PERMISSION_MODE:-acceptEdits} · extra repos via --add-dir"
}
adapter_init_claude() { CLAUDE_VERSION="${CLAUDE_VERSION:-$(claude --version 2>/dev/null | awk '{print $1; exit}')}"; }
adapter_check_claude() {  # read-only preflight: CLI present, auth status. Never runs a paid request.
  command -v claude >/dev/null 2>&1 || { say "  ✗ claude CLI not found on PATH"; return 1; }
  say "  ✓ claude $(command -v claude) ${CLAUDE_VERSION:-}"
  if claude auth status >/dev/null 2>&1; then say "  ✓ claude authenticated"; else say "  ✗ claude not authenticated (run: claude auth login)"; return 1; fi
}

adapter_codex() {  # Codex CLI: `codex exec`, prompt on stdin (`-`), workspace-write sandbox, never asks, extra repos via --add-dir
  local mode="$1" r
  AGENT_ARGV=(codex exec --sandbox "${CODEX_SANDBOX:-workspace-write}" -c 'approval_policy=never' -C "$PRIMARY_REPO" --skip-git-repo-check)
  [ "${CODEX_NETWORK_ACCESS:-1}" = 1 ] && AGENT_ARGV+=(-c 'sandbox_workspace_write.network_access=true')
  if [ "${#EXTRA_REPOS[@]}" -gt 0 ]; then for r in "${EXTRA_REPOS[@]}"; do AGENT_ARGV+=(--add-dir "$r"); done; fi
  [ "$LOOP_EPHEMERAL" = 1 ] && AGENT_ARGV+=(--ephemeral)
  [ -n "${CODEX_MODEL:-}" ] && AGENT_ARGV+=(--model "$CODEX_MODEL")
  [ -n "${CODEX_PROFILE:-}" ] && AGENT_ARGV+=(--profile "$CODEX_PROFILE")
  # shellcheck disable=SC2206
  [ -n "${AGENT_EXTRA_ARGS:-}" ] && AGENT_ARGV+=(${AGENT_EXTRA_ARGS})
  AGENT_ARGV+=(-)                                   # `-` = read the prompt from stdin (official)
  AGENT_STDIN=1; AGENT_NOTE="prompt on stdin (-) · sandbox ${CODEX_SANDBOX:-workspace-write} · approval never · extra repos via --add-dir"
}
adapter_init_codex() { CODEX_VERSION="${CODEX_VERSION:-$(codex --version 2>/dev/null | awk '{print $NF; exit}')}"; }
adapter_check_codex() {
  command -v codex >/dev/null 2>&1 || { say "  ✗ codex CLI not found on PATH"; return 1; }
  say "  ✓ codex $(command -v codex) ${CODEX_VERSION:-}"
  if codex login status >/dev/null 2>&1; then say "  ✓ codex authenticated"; else say "  ✗ codex not authenticated (run: codex login)"; return 1; fi
}

adapter_kimi() {  # Kimi Code (legacy, unverified): prompt as argument; verify your kimi version's headless flags
  local mode="$1"
  AGENT_ARGV=(kimi -p "$PROMPT")
  # shellcheck disable=SC2206
  [ -n "${AGENT_EXTRA_ARGS:-}" ] && AGENT_ARGV+=(${AGENT_EXTRA_ARGS})
  AGENT_STDIN=0; AGENT_NOTE="prompt as argument · extra repos: start from a common parent (kimi adapter is unverified)"
}
adapter_init_kimi() { :; }
adapter_check_kimi() { command -v kimi >/dev/null 2>&1 && say "  ✓ kimi $(command -v kimi)" || { say "  ✗ kimi CLI not found on PATH"; return 1; }; }

adapter_select() {  # adapter_select <mode> → fills AGENT_ARGV/AGENT_STDIN for $AGENT; exits on unknown agent
  case "$AGENT" in
    claude) adapter_claude "$1" ;;
    codex)  adapter_codex "$1" ;;
    kimi)   adapter_kimi "$1" ;;
    *) say "Unknown AGENT '$AGENT' (claude | codex | kimi)"; exit 2 ;;
  esac
}
adapter_init()  { case "$AGENT" in claude) adapter_init_claude;; codex) adapter_init_codex;; kimi) adapter_init_kimi;; esac; }
adapter_check() { case "$AGENT" in claude) adapter_check_claude;; codex) adapter_check_codex;; kimi) adapter_check_kimi;; *) say "  ✗ unknown AGENT '$AGENT'"; return 1;; esac; }
# ── end of agent adapters ───────────────────────────────────────────────────────

with_timeout() {  # with_timeout <sec> <argv…> — prefers coreutils timeout; bash fallback otherwise
  local t="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$@"; return $?; fi
  local pid w rc flag
  "$@" & pid=$!
  flag="${TMPDIR:-/tmp}/loop-timeout.$$.$pid"
  ( sleep "$t"; if kill -0 "$pid" 2>/dev/null; then : > "$flag"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null; fi ) >/dev/null 2>&1 &
  w=$!
  wait "$pid"; rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  if [ -f "$flag" ]; then rm -f "$flag"; return 124; fi
  return $rc
}

run_agent() {  # run_agent <mode> ; uses $PROMPT; one fresh agent process from the primary repo, under the watchdog
  local mode="$1" rc
  adapter_select "$mode"
  cd "$PRIMARY_REPO" || { say "cannot cd to $PRIMARY_REPO"; return 1; }
  if [ "$AGENT_STDIN" = 1 ]; then
    printf '%s\n' "$PROMPT" | LOOP_PILOT_NESTED=1 LOOP_PILOT_MODE="$mode" LOOP_PILOT_FEATURE="$FEATURE" with_timeout "$PHASE_TIMEOUT_SEC" "${AGENT_ARGV[@]}"
    rc=$?
  else
    LOOP_PILOT_NESTED=1 LOOP_PILOT_MODE="$mode" LOOP_PILOT_FEATURE="$FEATURE" with_timeout "$PHASE_TIMEOUT_SEC" "${AGENT_ARGV[@]}" </dev/null
    rc=$?
  fi
  return $rc
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
gates() { row "$1" | awk -F'|' '{n=NF-2; gsub(/^ +| +$/,"",$n); print $n}'; }
notes() { row "$1" | awk -F'|' '{n=NF-1; gsub(/^ +| +$/,"",$n); print $n}'; }
phases(){ grep -E '^\| *P[0-9][^ |]* *\|' "$STATUS" | awk -F'|' '{gsub(/ /,"",$2); print $2}'; }

is_at_keyboard() { local k; for k in "${AT_KEYBOARD[@]:-}"; do [ -n "$k" ] && [ "$1" = "$k" ] && return 0; done; return 1; }

set_state() {  # set_state <phase> <new-state> — edits only the State cell
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

append_notes() {  # append_notes <phase> <text> — appends to the Notes cell (last cell) of the row
  lock_acquire "$STATUS_LOCK"
  python3 - "$STATUS" "$1" "$2" <<'PY'
import re,sys
p,ph,txt=sys.argv[1],sys.argv[2],sys.argv[3]
lines=open(p).read().split("\n")
head=re.compile(rf'^\| *{re.escape(ph)} *\|')
for i,l in enumerate(lines):
    if head.match(l):
        cells=l.split("|")
        if len(cells)>=3:
            cur=cells[-2].strip()
            cells[-2]=" "+(cur+" · " if cur and cur!="—" else "")+txt+" "
            lines[i]="|".join(cells)
        break
open(p,'w').write("\n".join(lines))
PY
  lock_release "$STATUS_LOCK"
}

note() {
  lock_acquire "$STATUS_LOCK"
  printf -- "- [loop] %s\n" "$1" >> "$STATUS"
  lock_release "$STATUS_LOCK"
  printf 'LOOP: %s\n' "$1"
}

# ── prompts.md section readers (heading match is boundary-anchored: P1 ≠ P12) ─
_sec() { awk -v h="$1" '$0 ~ "^## "h"([^0-9A-Za-z]|$)" {f=1; next} f && /^## / {exit} f {print}' "$PROMPTS"; }
extract_block() { awk -v h="$1" '$0 ~ "^## "h"([^0-9A-Za-z]|$)" {f=1} f && /^```/ {c++; next} f && c==1 {print} c==2 {exit}' "$PROMPTS"; }
owner_lines()   { _sec "$1" | awk '/^> OWNER:/ {sub(/^> OWNER:[ ]*/,""); print}'; }
qa_lines()      { _sec "$1" | awk '/^> QA:/ {sub(/^> QA:[ ]*/,""); print}'; }
gate_cmd()      { _sec "$1" | awk '/^> GATE:/ {sub(/^> GATE:[ ]*/,""); print; exit}'; }
lane_raw()      { _sec "$1" | awk '/^> LANE:/ {sub(/^> LANE:[ ]*/,""); print; exit}'; }
human_only()    { _sec "$1" | awk '/^> HUMAN-ONLY:/ {sub(/^> HUMAN-ONLY:[ ]*/,""); print; exit}'; }
is_human_only() { [ -n "$(human_only "$1")" ]; }

lane_of() {  # a phase with no LANE line gets a private lane, i.e. no constraint
  local l; l="$(lane_raw "$1" | tr -d '`' | xargs 2>/dev/null || true)"
  if [ -n "$l" ]; then printf '%s\n' "$l"; else printf '@%s\n' "$1"; fi
}
is_solo() {  # explicit solo lanes, and every attempted at-keyboard phase (risk runs alone)
  is_at_keyboard "$1" && return 0
  case "$(lane_of "$1")" in solo|exclusive|alone) return 0;; *) return 1;; esac
}

# ── wave table (the plan's authority on what may run together) ────────────────
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
wave_mates() {  # unfinished phases the table puts alongside $1
  local w p out=""
  w="$(wave_of "$1")"; [ -z "$w" ] && return 0
  for p in $(printf '%s\n' "$WAVE_MAP" | awk -v w="$w" '$1==w {print $2}'); do
    [ "$p" = "$1" ] && continue
    is_human_only "$p" && continue
    case "$(state "$p")" in done|qa-pending) continue;; esac
    out="$out $p"
  done
  printf '%s\n' "$out" | xargs 2>/dev/null || true
}

# ── notifications ─────────────────────────────────────────────────────────────
notify() {  # notify <title> <body> — best effort, backgrounded, never blocks the run
  local s
  for s in "${LOOP_PILOT_NOTIFY:-}" "${LOOP_PILOT_HOME:-}/scripts/notify.sh" \
           "$HOME/.claude/skills/loop-pilot/scripts/notify.sh" "$HOME/.agents/skills/loop-pilot/scripts/notify.sh" \
           "$HOME/.codex/skills/loop-pilot/scripts/notify.sh"; do
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
  notify "$FEATURE: fleet paused" "Rate/usage limit hit. Every loop pauses at its next phase boundary and resumes in ~${1}m."
}

# ── run bookkeeping (file-backed: workers are subshells) ───────────────────────
skip()       { : > "$RUNDIR/skip.$1"; }
is_skipped() { [ -f "$RUNDIR/skip.$1" ]; }
mark_swept() { : > "$RUNDIR/swept.$1"; }
was_swept()  { [ -f "$RUNDIR/swept.$1" ]; }
runinfo_set() {  # runinfo_set key value — key=value file read by status.sh / dashboard
  local k="$1" v="$2" tmp
  tmp="$RUNINFO.tmp.$$"
  { [ -f "$RUNINFO" ] && grep -v "^$k=" "$RUNINFO"; printf '%s=%s\n' "$k" "$v"; } > "$tmp" 2>/dev/null
  mv "$tmp" "$RUNINFO"
}

# ── clobber repair ────────────────────────────────────────────────────────────
# The loop's own status.md writes are serialized, but the AGENTS' are not. A session that
# rewrites the whole table from a stale read can revert a sibling's settled row, so the
# loop remembers every done/qa-pending IT confirmed and restores any row that regresses.
confirm_settled() { printf '%s\n' "$2" > "$RUNDIR/settled.$1"; }
repair_rows() {
  local f ph want have
  for f in "$RUNDIR"/settled.*; do
    [ -e "$f" ] || continue
    ph="$(basename "$f")"; ph="${ph#settled.}"; want="$(cat "$f")"; have="$(state "$ph")"
    if [ "$have" != "$want" ]; then
      set_state "$ph" "$want"
      note "repaired $ph: row read '$have' but this loop confirmed it $want — a concurrent session overwrote it"
    fi
  done
}

# ── dependency semantics (the v4 contract) ────────────────────────────────────
dep_satisfied() {  # dep_satisfied <dep-phase> → 0 if a dependent may proceed
  case "$(state "$1")" in
    done) return 0 ;;
    qa-pending) [ "$STRICT_DEPS" = 1 ] && return 1 || return 0 ;;
    *) return 1 ;;
  esac
}
dep_dead() {  # a dep that will never complete in THIS run (what the forward sweep crosses)
  local st; st="$(state "$1")"
  case "$st" in
    blocked) return 0 ;;
    todo|in-progress) is_human_only "$1" && return 0; is_skipped "$1" && return 0
                      [ "$AT_KEYBOARD_MODE" = defer ] && is_at_keyboard "$1" && return 0
                      [ "$STRICT_DEPS" = 1 ] && [ "$st" = "in-progress" ] && return 0
                      return 1 ;;
    qa-pending) [ "$STRICT_DEPS" = 1 ] && return 0 || return 1 ;;   # only dead when strict
    *) return 1 ;;
  esac
}
deps_done() {  # every dep satisfied
  local d; d="$(deps "$1")"
  [ "$d" = "—" ] || [ -z "$d" ] && return 0
  local dep; for dep in ${d//,/ }; do dep_satisfied "$dep" || return 1; done
  return 0
}
deps_done_or_dead() {  # sweep mode: every dep satisfied or provably dead (nothing in flight)
  local d; d="$(deps "$1")"
  [ "$d" = "—" ] || [ -z "$d" ] && return 0
  local dep; for dep in ${d//,/ }; do dep_satisfied "$dep" || dep_dead "$dep" || return 1; done
  return 0
}
degraded_deps() {  # the dead deps of $1, for the notice — "P2(blocked: notes) P4(human-only)"
  local d dep out=""; d="$(deps "$1")"
  [ "$d" = "—" ] || [ -z "$d" ] && return 0
  for dep in ${d//,/ }; do
    dep_satisfied "$dep" && continue
    if is_human_only "$dep"; then out="$out $dep(human-only: $(human_only "$dep"))"
    else out="$out $dep($(state "$dep"): $(notes "$dep"))"; fi
  done
  printf '%s\n' "$out" | sed 's/^ //'
}

# ── in-flight bookkeeping (parent only) ───────────────────────────────────────
RUNNING=""                                     # "P2:1234 P5:1240"
running_phases() { local e; for e in $RUNNING; do printf '%s\n' "${e%%:*}"; done; }
running_count()  { local e n=0; for e in $RUNNING; do n=$((n+1)); done; printf '%s\n' "$n"; }
is_running()     { local p; for p in $(running_phases); do [ "$p" = "$1" ] && return 0; done; return 1; }
publish_inflight() { running_phases | tr '\n' ' ' > "$RUNDIR/inflight"; }
sibs_of() { tr ' ' '\n' < "$RUNDIR/inflight" 2>/dev/null | grep -v "^$1$" | grep -v '^$' | tr '\n' ' ' | xargs 2>/dev/null || true; }
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
attemptable() {  # may the loop dispatch $1 at all this run?
  [ "$(state "$1")" = "todo" ] || return 1
  is_human_only "$1" && return 1
  [ "$AT_KEYBOARD_MODE" = defer ] && is_at_keyboard "$1" && return 1
  is_skipped "$1" && return 1
  is_running "$1" && return 1
  return 0
}
SWEEP=0
next_dispatchable() {  # first phase eligible to start right now, or ""
  local ph
  for ph in $(phases); do
    attemptable "$ph" || continue
    if [ "$SWEEP" = 1 ]; then deps_done_or_dead "$ph" || continue; else deps_done "$ph" || continue; fi
    lane_free "$ph" || continue
    wave_ok "$ph" || continue
    printf '%s\n' "$ph"; return
  done
  printf '\n'
}
any_stranded() {  # an attemptable phase exists whose deps are settled-or-dead but not settled
  local ph
  for ph in $(phases); do
    attemptable "$ph" || continue
    deps_done "$ph" && continue
    deps_done_or_dead "$ph" && return 0
  done
  return 1
}
all_settled() { local ph; for ph in $(phases); do case "$(state "$ph")" in done|qa-pending) ;; *) return 1;; esac; done; return 0; }

# ── QA.md — the owner's tickable test list, written at EVERY ending ───────────
write_qa() {
  local ph st n=0 l started ended
  started="$(grep '^started_at=' "$RUNINFO" 2>/dev/null | cut -d= -f2-)"; ended="$(date '+%Y-%m-%d %H:%M')"
  {
    echo "# QA — $FEATURE"
    echo
    echo "Run started ${started:-?} · ended $ended · agent $AGENT · result **${RESULT:-?}**"
    echo "Tick boxes here or in the loop-pilot dashboard. Sections 1–3 need you; section 4 is done and gate-verified."
    echo
    echo "## 1. Verify these (complete — awaiting your eyes)"
    for ph in $(phases); do
      [ "$(state "$ph")" = "qa-pending" ] || continue
      n=$((n+1)); echo "- [ ] **$ph** — $(notes "$ph")"
      while IFS= read -r l; do [ -n "$l" ] && { n=$((n+1)); echo "  - [ ] QA: $l"; }; done <<EOF
$(qa_lines "$ph")
EOF
      if is_at_keyboard "$ph"; then while IFS= read -r l; do [ -n "$l" ] && { n=$((n+1)); echo "  - [ ] OWNER: $l"; }; done <<EOF
$(owner_lines "$ph")
EOF
      fi
    done
    echo
    echo "## 2. Defects the loop could not clear"
    for ph in $(phases); do
      st="$(state "$ph")"
      case "$st" in done|qa-pending) continue;; esac
      is_human_only "$ph" && continue
      [ "$AT_KEYBOARD_MODE" = defer ] && is_at_keyboard "$ph" && continue
      n=$((n+1))
      case "$st" in
        blocked)  echo "- [ ] **$ph** (blocked) — $(notes "$ph") · logs: logs/$ph-*" ;;
        *)        echo "- [ ] **$ph** ($st) — never ran to a terminal state; deps: $(deps "$ph") · $(notes "$ph")" ;;
      esac
    done
    echo
    echo "## 3. Only you can do these"
    for ph in $(phases); do
      st="$(state "$ph")"
      case "$st" in done|qa-pending) continue;; esac
      if is_human_only "$ph"; then n=$((n+1)); echo "- [ ] **$ph** — HUMAN-ONLY: $(human_only "$ph") (state: $st, deps: $(deps "$ph"))"
      elif [ "$AT_KEYBOARD_MODE" = defer ] && is_at_keyboard "$ph"; then n=$((n+1)); echo "- [ ] **$ph** — at-keyboard (deferred; state: $st, deps: $(deps "$ph"))"
      else continue; fi
      while IFS= read -r l; do [ -n "$l" ] && { n=$((n+1)); echo "  - [ ] OWNER: $l"; }; done <<EOF
$(owner_lines "$ph")
EOF
      while IFS= read -r l; do [ -n "$l" ] && { n=$((n+1)); echo "  - [ ] QA: $l"; }; done <<EOF
$(qa_lines "$ph")
EOF
    done
    echo
    echo "## 4. Done and gate-verified"
    for ph in $(phases); do
      [ "$(state "$ph")" = "done" ] || continue
      echo "- [x] **$ph** — gates: $(gates "$ph")"
      while IFS= read -r l; do [ -n "$l" ] && echo "  - [ ] QA: $l"; done <<EOF
$(qa_lines "$ph")
EOF
    done
  } > "$QA_FILE"
  QA_ITEMS="$n"
  say "LOOP: QA.md written → $QA_FILE ($n item(s) for you)"
}

finish_run() {  # AUDIT in a fresh process, then QA.md, .runinfo, notify. Every ending comes here.
  local defects=0 ph
  repair_rows
  if [ "${NO_AUDIT:-0}" != 1 ]; then
    say "LOOP: running AUDIT in a fresh $AGENT process"
    wait_if_paused
    PROMPT="$(extract_block 'AUDIT')"
    if [ -n "$PROMPT" ]; then
      run_agent audit > "$PLOGS/AUDIT-$(date +%H%M%S).log" 2>&1
      say "LOOP: audit complete — read $FEATURE_DIR/audit-*.md, worst finding first."
    else
      note "no AUDIT block in prompts.md — audit skipped (scaffolding gap)"
    fi
  fi
  for ph in $(phases); do case "$(state "$ph")" in done|qa-pending) ;; *) defects=$((defects+1));; esac; done
  if [ "$defects" -eq 0 ]; then RESULT=COMPLETE; else RESULT=INCOMPLETE; fi
  runinfo_set ended "$(date +%s)"; runinfo_set ended_at "$(date '+%Y-%m-%d %H:%M')"; runinfo_set result "$RESULT"
  write_qa
  runinfo_set qa_items "$QA_ITEMS"; runinfo_set defects "$defects"
  note "run $RESULT — $QA_ITEMS QA item(s) for the owner, $defects defect(s)"
  notify "$FEATURE: $RESULT" "$QA_ITEMS item(s) in QA.md ($defects defect(s)). Read: $QA_FILE"
  rm -rf "$RUNDIR"
  exit 0
}

# ── CLI: --preflight / --version / --help (all read-only; nothing above mutated state) ──
load_waves || true
case "${1:-}" in
  --version) grep -m1 '^# template-version:' "$0"; grep -m1 '^# template-sha:' "$0" 2>/dev/null; exit 0 ;;
  --help|-h)
    say "usage: [AGENT=claude|codex|kimi] $0 [--preflight|--plan|--version]"
    say "env: MAX_PARALLEL PARALLEL_MODE STRICT_DEPS AT_KEYBOARD_MODE FORCE_FORWARD PHASE_TIMEOUT_SEC MAX_RETRIES LOOP_EPHEMERAL LOOP_EXTRA_REPOS"
    say "     CLAUDE_PERMISSION_MODE CLAUDE_ALLOWED_TOOLS CLAUDE_DISALLOWED_TOOLS CLAUDE_PERMISSION_PROMPTS CLAUDE_MODEL"
    say "     CODEX_SANDBOX CODEX_NETWORK_ACCESS CODEX_MODEL CODEX_PROFILE AGENT_EXTRA_ARGS"; exit 0 ;;
  --preflight|--plan)
    adapter_init; PROMPT="<phase prompt>"; adapter_select phase
    echo "PREFLIGHT — $FEATURE   (template v5 · A→Z contract · read-only, nothing is changed)"
    echo "Agent: $AGENT — $AGENT_NOTE"
    printf '  argv:'; for a in "${AGENT_ARGV[@]}"; do case "$a" in "$PROMPT") printf ' <prompt>';; *' '*|'') printf " '%s'" "$a";; *) printf ' %s' "$a";; esac; done; echo
    adapter_check || echo "  ⚠ fix the above before flying (the loop would fail every phase)"
    echo "Repos:"
    [ -d "$PRIMARY_REPO" ] && echo "  ✓ primary $PRIMARY_REPO" || echo "  ✗ primary $PRIMARY_REPO (missing)"
    if [ "${#EXTRA_REPOS[@]}" -gt 0 ]; then for r in "${EXTRA_REPOS[@]}"; do [ -d "$r" ] && echo "  ✓ extra   $r" || echo "  ✗ extra   $r (missing — the agent would refuse it)"; done
    else echo "  (no extra repos)"; fi
    echo "Contract: STRICT_DEPS=$STRICT_DEPS ($([ "$STRICT_DEPS" = 1 ] && echo 'only done satisfies a dependency' || echo 'qa-pending satisfies dependencies')) · AT_KEYBOARD_MODE=$AT_KEYBOARD_MODE · FORCE_FORWARD=$FORCE_FORWARD · retries=$MAX_RETRIES · watchdog=${PHASE_TIMEOUT_SEC}s"
    command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || echo "  ⚠ no coreutils timeout — bash fallback watchdog in use (brew install coreutils for the real one)"
    echo "Parallelism: MAX_PARALLEL=$MAX_PARALLEL, mode=$PARALLEL_MODE, wave table: $WAVE_SRC"
    if [ -n "$WAVE_MAP" ]; then
      echo "Dispatch groups (phases on one line start together, slots permitting):"
      for w in $(printf '%s\n' "$WAVE_MAP" | awk '{print $1}' | sort -n -u); do
        grp=""; solo=""
        for p in $(printf '%s\n' "$WAVE_MAP" | awk -v w="$w" '$1==w {print $2}'); do
          if is_human_only "$p"; then solo="$solo $p(HUMAN-ONLY)"
          elif is_at_keyboard "$p"; then solo="$solo $p(at-keyboard,$AT_KEYBOARD_MODE)"
          elif is_solo "$p"; then solo="$solo $p(solo)"
          else ln="$(lane_raw "$p" | xargs 2>/dev/null || true)"; if [ -n "$ln" ]; then grp="$grp ${p}[$ln]"; else grp="$grp $p"; fi; fi
        done
        echo "  wave $w:${grp:- —}${solo:+   run alone:$solo}"
      done
      for p in $(phases); do [ -z "$(wave_of "$p")" ] && echo "  ⚠ $p is in no wave row — it will run ALONE"; done
    else
      echo "  no wave table found — every phase runs alone. Add an 'Order and parallelism' table to prompts.md, or run with PARALLEL_MODE=deps."
    fi
    echo
    echo "HUMAN-ONLY phases (the loop will NEVER attempt these — they land in QA.md section 3):"
    hn=0; for k in $(phases); do is_human_only "$k" || continue; hn=1; echo "- $k (state: $(state "$k"), deps: $(deps "$k")) — $(human_only "$k")"; owner_lines "$k" | sed 's/^/    owner: /'; done
    [ "$hn" = 0 ] && echo "  _none_"
    echo
    if [ "$AT_KEYBOARD_MODE" = defer ]; then echo "At-keyboard phases (AT_KEYBOARD_MODE=defer: routed around, yours to run):"
    else echo "At-keyboard phases (AT_KEYBOARD_MODE=attempt: the loop WILL attempt these alone and end them qa-pending):"; fi
    if [ -n "${AT_KEYBOARD[*]:-}" ]; then
      for k in "${AT_KEYBOARD[@]}"; do [ -n "$k" ] || continue; is_human_only "$k" && continue
        echo "- $k (state: $(state "$k"), deps: $(deps "$k")). Owner checklist:"; owner_lines "$k" | sed 's/^/    - /'; done
    else echo "  _none — this run can go start to audit with zero owner input_"; fi
    echo
    echo "QA lines (become tick boxes in QA.md):"; qn=0
    for k in $(phases); do while IFS= read -r l; do [ -n "$l" ] && { qn=1; echo "- $k: $l"; }; done <<EOF
$(qa_lines "$k")
EOF
    done; [ "$qn" = 0 ] && echo "  _none — QA.md will list phase IDs only; add > QA: lines under phase headings_"
    echo
    echo "Gates found in prompts.md (run BY THE LOOP after the agent claims done):"
    for k in $(phases); do g="$(gate_cmd "$k")"; [ -n "$g" ] && echo "- $k: $g"; done
    echo
    echo "Anything front-loadable above? Do it NOW, mark the phase done in status.md, and the unattended run covers everything else in one pass."
    exit 0 ;;
  '') : ;;
  *) say "unknown option: $1 (try --help)"; exit 2 ;;
esac

# ── Guards (only past this point does the run mutate anything) ────────────────
if [ -n "${LOOP_PILOT_NESTED:-}" ]; then
  say "loop.sh: REFUSING to start — this shell is inside an agent phase of a loop-pilot run (LOOP_PILOT_NESTED=1). A phase must never launch another orchestration."
  exit 3
fi
if [ -f "$RUNINFO" ] && ! grep -q '^ended=' "$RUNINFO" 2>/dev/null; then
  _opid="$(grep '^pid=' "$RUNINFO" | cut -d= -f2)"
  if [ -n "$_opid" ] && kill -0 "$_opid" 2>/dev/null && [ "${LOOP_FORCE:-0}" != 1 ]; then
    say "loop.sh: a loop for $FEATURE is already running (pid $_opid). Refusing a double start (LOOP_FORCE=1 overrides)."; exit 4
  fi
fi
[ -f "$STATUS" ] && [ -f "$PROMPTS" ] || { say "loop.sh: $STATUS or $PROMPTS missing — scaffolding gap, run grillscaffold"; exit 2; }
[ -d "$PRIMARY_REPO" ] || { say "loop.sh: primary repo missing: $PRIMARY_REPO"; exit 2; }
if [ "${#EXTRA_REPOS[@]}" -gt 0 ]; then for _r in "${EXTRA_REPOS[@]}"; do [ -d "$_r" ] || { say "loop.sh: extra repo missing: $_r"; exit 2; }; done; fi
adapter_init
mkdir -p "$PLOGS"; rm -rf "$RUNDIR"; mkdir -p "$RUNDIR"
rmdir "$STATUS_LOCK" "$GATE_LOCK" 2>/dev/null   # a previous run killed mid-write leaves these
rm -f "$RUNINFO"
runinfo_set started "$(date +%s)"; runinfo_set started_at "$(date '+%Y-%m-%d %H:%M')"; runinfo_set pid "$$"
runinfo_set agent "$AGENT"; runinfo_set template 5; runinfo_set max_parallel "$MAX_PARALLEL"; runinfo_set parallel_mode "$PARALLEL_MODE"
runinfo_set strict_deps "$STRICT_DEPS"; runinfo_set at_keyboard_mode "$AT_KEYBOARD_MODE"; runinfo_set force_forward "$FORCE_FORWARD"

# Stale-state recovery: a row left in-progress by a killed run is poison (nothing selects it,
# nothing may build on it). Reset it to blocked so it surfaces as a defect for the owner.
for _ph in $(phases); do
  if [ "$(state "$_ph")" = "in-progress" ]; then
    set_state "$_ph" "blocked"
    note "reset stale in-progress $_ph to blocked (left by a previous interrupted run — inspect its diff/patches before rerunning)"
  fi
done

# ── Phase worker — the whole lifecycle of ONE phase, run in the background ─────
# Writes its outcome to $RUNDIR/<PH>.result: done | settled | skipped
phase_worker() {
  local PH="$1" BLOCK GATE attempt RC ST PHLOG GLOG SIBS FAILCTX DEGRADED

  BLOCK="$(extract_block "$PH")"
  if [ -z "$BLOCK" ]; then
    set_state "$PH" "blocked"
    note "routed around $PH: no prompt block found in prompts.md"
    echo "skipped" > "$RUNDIR/$PH.result"; return
  fi
  DEGRADED=""; was_swept "$PH" && DEGRADED="$(degraded_deps "$PH")"

  GATE="$(gate_cmd "$PH")"
  attempt=0; FAILCTX=""
  while :; do
    wait_if_paused
    attempt=$((attempt+1))
    PHLOG="$PLOGS/$PH-attempt$attempt-$(date +%H%M%S).log"

    PROMPT="$BLOCK"
    if [ "$MAX_PARALLEL" -gt 1 ]; then
      SIBS="$(printf '%s %s' "$(sibs_of "$PH")" "$(wave_mates "$PH")" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | xargs 2>/dev/null || true)"
    else SIBS=""; fi
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
    if is_at_keyboard "$PH"; then
      PROMPT="UNATTENDED ATTEMPT OF A SUPERVISED PHASE. This phase was planned as at-keyboard, but
no human is present: this is an unattended run and nobody can answer a question. Do everything
in scope that needs no human hand and nothing irreversible: write the code, config, rules files,
migration scripts and tests. Do NOT touch production, live data, payments, a physical device, or
run any destructive migration — where the plan asks you to \"stop and ask\", do not ask: leave
that step undone and describe it precisely. End this phase as qa-pending (never done), with the
Notes cell written as instructions for the owner: exactly which steps remain and how to verify.
Owner checklist from the plan:
$(owner_lines "$PH" | sed 's/^/- /')

$PROMPT"
    fi
    if [ -n "$DEGRADED" ]; then
      PROMPT="DEGRADED DEPENDENCY NOTICE. This phase depends on work that never completed in this
run: $DEGRADED. The loop is sweeping you forward anyway so the rest of the feature is not held
hostage. Build everything in your scope that does not need the missing part; cross the gap with
the smallest honest placeholder rather than reimplementing the missing phase; name every gap in
your Notes cell; and end qa-pending, not done, if anything was built against a placeholder.

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
    PROMPT="You are one phase ($PH) of an unattended loop-pilot run of feature '$FEATURE'. Do not
invoke the loop-pilot or grillscaffold skills, do not run loop.sh, and do not start any other
orchestration — do exactly this phase, then stop.

$PROMPT"

    say "LOOP: phase $PH attempt $attempt → fresh $AGENT process (timeout ${PHASE_TIMEOUT_SEC}s, log: $PHLOG)"
    set_state "$PH" "in-progress"
    run_agent phase > "$PHLOG" 2>&1
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
    if [ "$ST" = "done" ] && is_at_keyboard "$PH" && [ "${AT_KEYBOARD_DONE_OK:-0}" != 1 ]; then
      set_state "$PH" "qa-pending"; ST="qa-pending"
      append_notes "$PH" "attempted unattended (at-keyboard phase) — owner verification required before this counts as done"
      note "$PH was attempted unattended and claims done — downgraded to qa-pending (AT_KEYBOARD_DONE_OK=1 to accept)"
    fi
    if [ "$ST" = "done" ]; then
      if [ -n "$GATE" ]; then
        GLOG="$PLOGS/$PH-gate-attempt$attempt.log"
        say "LOOP: $PH waiting for the gate lock → $GATE"
        lock_acquire "$GATE_LOCK" 1800
        ( cd "$PRIMARY_REPO" && with_timeout "$GATE_TIMEOUT_SEC" bash -c "$GATE" ) > "$GLOG" 2>&1
        RC=$?
        if [ "$RC" -ne 0 ] && [ -n "$(sibs_of "$PH")" ]; then   # plausibly collateral: settle, retry once
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
          confirm_settled "$PH" done
          note "$PH done — gate passed: $GATE"
          echo "done" > "$RUNDIR/$PH.result"; return
        fi
      else
        confirm_settled "$PH" done
        say "LOOP: $PH done (no gate defined)"
        echo "done" > "$RUNDIR/$PH.result"; return
      fi
    elif [ "$ST" = "qa-pending" ]; then
      confirm_settled "$PH" qa-pending
      note "$PH qa-pending — complete, awaiting the owner's eyes: $(notes "$PH")"
      echo "settled" > "$RUNDIR/$PH.result"; return
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
        note "$PH ended silent without updating status.md (attempt $attempt, exit $RC)"
      fi
    else  # blocked by the agent's own hand (or an unknown state, treated the same)
      [ "$ST" = "blocked" ] || { set_state "$PH" "blocked"; note "$PH left in unknown state '$ST' — treated as blocked"; }
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
    note "recorded defect: $PH after $attempt attempt(s) — dependents proceed only via the forward sweep"
    notify "$FEATURE: $PH defect" "Blocked after $attempt attempts. Last note: $(notes "$PH")"
    echo "skipped" > "$RUNDIR/$PH.result"; return
  done
}

# ── Scheduler ─────────────────────────────────────────────────────────────────
say "LOOP: $FEATURE — agent=$AGENT, up to $MAX_PARALLEL phase(s) in flight (mode=$PARALLEL_MODE, waves from ${WAVE_SRC##*/}, strict_deps=$STRICT_DEPS, at_keyboard=$AT_KEYBOARD_MODE, force_forward=$FORCE_FORWARD)"

reap() {  # collect finished workers and apply their outcome
  local e ph pid still=""
  for e in $RUNNING; do
    ph="${e%%:*}"; pid="${e##*:}"
    if [ ! -f "$RUNDIR/$ph.result" ] && child_alive "$pid"; then still="$still $e"; continue; fi
    wait "$pid" 2>/dev/null
    case "$(cat "$RUNDIR/$ph.result" 2>/dev/null)" in
      done)    say "LOOP: $ph finished — done" ;;
      settled) say "LOOP: $ph finished — qa-pending (counts as complete)" ;;
      *)       skip "$ph"; say "LOOP: $ph finished — defect recorded" ;;
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
    if [ "$SWEEP" = 1 ] && ! deps_done "$PH"; then mark_swept "$PH"; note "forward sweep: dispatching $PH over degraded dependencies ($(degraded_deps "$PH"))"; fi
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

  # 2. nothing running and nothing dispatchable → sweep once, else the run is over
  if [ -z "$RUNNING" ]; then
    repair_rows
    if [ "$FORCE_FORWARD" = 1 ] && [ "$SWEEP" = 0 ] && [ "$DISPATCHED" -lt "$MAX_PHASES" ] && any_stranded; then
      SWEEP=1; note "forward sweep engaged — phases stranded behind failed or human-only work will run once with a degraded-dependency notice"
      continue
    fi
    [ "$DISPATCHED" -ge "$MAX_PHASES" ] && note "MAX_PHASES ($MAX_PHASES) reached — ending the run with whatever remains"
    finish_run
  fi

  # 3. wait for something to finish, then loop and refill
  sleep "$POLL_SEC"
  reap
  repair_rows
done
```

---

## Agent adapters — what each one does (and does not do)

| | Claude Code | Codex | Kimi (legacy) |
|---|---|---|---|
| Invocation | `claude -p` | `codex exec` | `kimi -p` |
| Prompt transport | stdin | stdin (`-`) | argument |
| Working directory | `cd $PRIMARY_REPO` | `cd` + `-C $PRIMARY_REPO` | `cd` |
| Write permissions | `--permission-mode acceptEdits --allowedTools Bash` plus deny rules for `git commit`/`git push`; `--permission-prompts none` when Claude Code ≥ 2.1.259 | `--sandbox workspace-write -c approval_policy=never` (never read-only, never asks); network on by default (`CODEX_NETWORK_ACCESS=0` to close it) | agent defaults |
| Extra repos | `--add-dir <path>` per repo | `--add-dir <path>` per repo | common parent directory |
| Ephemeral (`LOOP_EPHEMERAL=1`) | `--no-session-persistence` | `--ephemeral` | — |
| Auth preflight (read-only) | `claude auth status` | `codex login status` | `command -v kimi` |

Every phase gets a **fresh process**, an environment marker `LOOP_PILOT_NESTED=1` (this runner
refuses to start when it is set, so an agent can never recursively launch a loop), and paths with
spaces, apostrophes or other ordinary characters are passed as single argv elements, never
through a shell string. `AGENT_EXTRA_ARGS` is the escape hatch for extra flags on any agent;
`LOOP_EXTRA_REPOS` (newline-separated) overrides the rendered repo list for one run.

## Writing the wave table (what unlocks parallelism)

grillscaffold emits one in prompts.md under `## Order and parallelism` and in plan.md under
`## Concurrency and waves`. The runner reads prompts.md first. Only the numeric rows matter:

```markdown
| Wave | Run together |
|---|---|
| 1 | P0 |
| 2 | P2, P3 |
| 3 | P4 |
```

- Phases on the same row start together when their `Depends on` phases are settled.
- A phase **not listed in any row runs alone** — the safe default.
- Waves are barriers: nothing from wave 3 starts while a wave-2 phase is still in flight.
- `PARALLEL_MODE=deps` drops the barrier and dispatches purely on `Depends on` + lanes.

## Contract lines under a phase heading in prompts.md

- `> GATE: <shell command>` — run by the loop after the agent claims done; red revokes the claim.
- `> LANE: <name>` — at most one phase per lane in flight; `solo` runs alone.
- `> OWNER: <item>` — owner checklist for a supervised phase (preflight + QA.md surface it).
- `> QA: <instruction>` — copied verbatim into QA.md as a tick box.
- `> HUMAN-ONLY: <reason>` — the one hard brake: the loop never attempts the phase.

Gates are serialized across the feature by a mutex; a gate that goes red while siblings are in
flight is re-run once after `GATE_SETTLE_SEC`. Prefer targeted gates in parallel waves; keep the
full build for a wave of its own. Examples: `npx tsc --noEmit && npx eslint . --max-warnings 0` ·
`rm -rf .next && npx next build` · `npx vitest run src/lessons --reporter=dot` ·
`maestro test .maestro/<feature>-flow.yaml` (with `> LANE: emulator`) ·
`firebase hosting:channel:deploy <feature>` (with `> LANE: preview-deploy`).
