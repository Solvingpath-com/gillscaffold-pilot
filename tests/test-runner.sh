#!/usr/bin/env bash
# Runner tests: simulate whole loops with fake claude/codex/kimi binaries (no API, no credentials).
set -o pipefail
. "$(dirname "$0")/lib.sh"
echo "== runner tests (bash: $($BASH_BIN --version | head -1))"
export POLL_SEC=1 PHASE_TIMEOUT_SEC=20 GATE_SETTLE_SEC=1 LIMIT_BACKOFF_MIN=0

run_loop() {  # run_loop <fdir> [env…]  → runs loop.sh with the given env words, captures output
  local fdir="$1"; shift
  ( cd "$fdir" && env "$@" "$BASH_BIN" ./loop.sh ) > "$fdir/run.out" 2>&1
  echo $? > "$fdir/run.rc"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "-- 1. claude adapter: argv, stdin prompt byte-for-byte, extra repos with spaces"
mk_sandbox
PR="$SANDBOX/my repo"; E1="$SANDBOX/it's api"; E2="$SANDBOX/mobile app"
make_repo "$PR"; mkdir -p "$E1" "$E2"
EXTRA_REPO_LIST=("$E1" "$E2"); make_feature "$PR" feat-a $'P1|—|\nP2|P1|'
FD="$PR/docs/features/feat-a"; render_loop "$FD" feat-a "$PR" "$E1" "$E2"
printf 'P1=done\nP2=done\nAUDIT=audit\nversion=2.1.270\n' > "$FAKE_AGENT_SCRIPT"
run_loop "$FD" AGENT=claude MAX_PARALLEL=1
t_begin "loop exits 0"; assert '[ "$(cat "$FD/run.rc")" = 0 ]' "$(cat "$FD/run.out")"
t_begin "claude selected as executable"; assert '[ "$(sed -n 1p "$FAKE_AGENT_LOG_DIR/1.argv")" = claude ]'
t_begin "claude argv: -p, permission-mode acceptEdits, allowedTools Bash"; assert 'grep -qx -- "-p" "$FAKE_AGENT_LOG_DIR/1.argv" && grep -qx -- "acceptEdits" "$FAKE_AGENT_LOG_DIR/1.argv" && grep -qx -- "--allowedTools" "$FAKE_AGENT_LOG_DIR/1.argv"' "$(argv_of 1)"
t_begin "claude argv: git commit/push denied at tool level"; assert 'grep -q "Bash(git push \*)" "$FAKE_AGENT_LOG_DIR/1.argv"'
t_begin "claude argv: --permission-prompts none (version 2.1.270 ≥ 2.1.259)"; assert 'grep -qx -- "--permission-prompts" "$FAKE_AGENT_LOG_DIR/1.argv"' "$(argv_of 1)"
t_begin "claude argv: both extra repos passed as single --add-dir elements (spaces, apostrophe)"; assert 'grep -qxF -- "$E1" "$FAKE_AGENT_LOG_DIR/1.argv" && grep -qxF -- "$E2" "$FAKE_AGENT_LOG_DIR/1.argv" && [ "$(grep -cx -- "--add-dir" "$FAKE_AGENT_LOG_DIR/1.argv")" = 2 ]' "$(argv_of 1)"
t_begin "claude: no positional prompt (stdin transport)"; assert '[ "$(grep -c . "$FAKE_AGENT_LOG_DIR/1.env")" -gt 0 ] && grep -q "stdin_used=1" "$FAKE_AGENT_LOG_DIR/1.env"'
EXPECT="You are one phase (P1) of an unattended loop-pilot run of feature 'feat-a'. Do not
invoke the loop-pilot or grillscaffold skills, do not run loop.sh, and do not start any other
orchestration — do exactly this phase, then stop.

$(awk '/^## P1/{f=1} f&&/^```/{c++;next} f&&c==1{print} c==2{exit}' "$FD/prompts.md")"
t_begin "prompt on stdin is byte-for-byte the phase block (plus the fixed nesting preamble)"; assert '[ "$(cat "$FAKE_AGENT_LOG_DIR/1.stdin")" = "$EXPECT" ]' "$(diff <(printf '%s' "$EXPECT") "$FAKE_AGENT_LOG_DIR/1.stdin")"
t_begin "cwd is the primary repo; LOOP_PILOT_NESTED=1 and LOOP_PILOT_FEATURE exported"; assert 'grep -qF "cwd=$PR" "$FAKE_AGENT_LOG_DIR/1.env" && grep -q "LOOP_PILOT_NESTED=1" "$FAKE_AGENT_LOG_DIR/1.env" && grep -q "LOOP_PILOT_FEATURE=feat-a" "$FAKE_AGENT_LOG_DIR/1.env" && grep -q "LOOP_PILOT_MODE=phase" "$FAKE_AGENT_LOG_DIR/1.env"'
t_begin "AUDIT ran in a fresh process (mode=audit) and wrote audit-*.md"; assert 'ls "$FD"/audit-*.md >/dev/null 2>&1 && grep -q "LOOP_PILOT_MODE=audit" "$FAKE_AGENT_LOG_DIR/3.env"'
t_begin "QA.md written with four sections"; assert '[ "$(grep -c "^## [1-4]\." "$FD/QA.md")" = 4 ]' "$(cat "$FD/QA.md")"
t_begin ".runinfo says COMPLETE with started/ended"; assert 'grep -q "^result=COMPLETE" "$FD/.runinfo" && grep -q "^started=" "$FD/.runinfo" && grep -q "^ended=" "$FD/.runinfo" && grep -q "^agent=claude" "$FD/.runinfo"' "$(cat "$FD/.runinfo")"
rm_sandbox

# ─────────────────────────────────────────────────────────────────────────────
echo "-- 2. codex adapter: exec, workspace-write, never-ask, -C, --add-dir, stdin via -, exit code"
mk_sandbox
PR="$SANDBOX/repo one"; E1="$SANDBOX/extra 1"; make_repo "$PR"; mkdir -p "$E1"
EXTRA_REPO_LIST=("$E1"); make_feature "$PR" feat-c $'P1|—|'
FD="$PR/docs/features/feat-c"; render_loop "$FD" feat-c "$PR" "$E1"
printf 'P1=done\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"
run_loop "$FD" AGENT=codex MAX_PARALLEL=1 LOOP_EPHEMERAL=1
t_begin "codex selected"; assert '[ "$(sed -n 1p "$FAKE_AGENT_LOG_DIR/1.argv")" = codex ] && [ "$(sed -n 2p "$FAKE_AGENT_LOG_DIR/1.argv")" = exec ]'
t_begin "codex argv: --sandbox workspace-write (never read-only)"; assert 'grep -qx -- "--sandbox" "$FAKE_AGENT_LOG_DIR/1.argv" && grep -qx -- "workspace-write" "$FAKE_AGENT_LOG_DIR/1.argv" && ! grep -qx -- "read-only" "$FAKE_AGENT_LOG_DIR/1.argv"' "$(argv_of 1)"
t_begin "codex argv: approval never, no --yolo, no danger-full-access"; assert 'grep -qx -- "approval_policy=never" "$FAKE_AGENT_LOG_DIR/1.argv" && ! grep -q -- "danger" "$FAKE_AGENT_LOG_DIR/1.argv" && ! grep -q -- "yolo" "$FAKE_AGENT_LOG_DIR/1.argv"' "$(argv_of 1)"
t_begin "codex argv: -C primary (with space) as one element, --add-dir extra"; assert 'grep -qx -- "-C" "$FAKE_AGENT_LOG_DIR/1.argv" && grep -qxF -- "$PR" "$FAKE_AGENT_LOG_DIR/1.argv" && grep -qx -- "--add-dir" "$FAKE_AGENT_LOG_DIR/1.argv" && grep -qxF -- "$E1" "$FAKE_AGENT_LOG_DIR/1.argv"' "$(argv_of 1)"
t_begin "codex argv: prompt via stdin (last arg is -), --ephemeral honoured, --skip-git-repo-check"; assert '[ "$(tail -1 "$FAKE_AGENT_LOG_DIR/1.argv")" = "-" ] && grep -qx -- "--ephemeral" "$FAKE_AGENT_LOG_DIR/1.argv" && grep -qx -- "--skip-git-repo-check" "$FAKE_AGENT_LOG_DIR/1.argv"'
t_begin "codex received the prompt on stdin"; assert 'grep -q "stdin_used=1" "$FAKE_AGENT_LOG_DIR/1.env" && grep -q "one phase (P1)" "$FAKE_AGENT_LOG_DIR/1.stdin"'
t_begin "codex network access on by default (config override)"; assert 'grep -qx -- "sandbox_workspace_write.network_access=true" "$FAKE_AGENT_LOG_DIR/1.argv"'
t_begin "COMPLETE"; assert 'grep -q "^result=COMPLETE" "$FD/.runinfo"'
# exit-code propagation: an exit 7 silent session is recorded with its code, retried, then a defect
printf 'P1=exit:7\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"; rm -rf "$FAKE_AGENT_LOG_DIR"/*; rm -f "$FD/.runinfo"
python3 - "$FD/status.md" <<'PY'
import re,sys; p=sys.argv[1]; s=open(p).read(); s=re.sub(r'^(\| *P1 *\| *)[^|]*(\|)',r'\g<1>todo \g<2>',s,count=1,flags=re.M); open(p,'w').write(s)
PY
run_loop "$FD" AGENT=codex MAX_PARALLEL=1
t_begin "agent exit code propagated into the evidence (exit 7) and the phase retried once"; assert 'grep -q "exit 7" "$FD/status.md" && [ -f "$FAKE_AGENT_LOG_DIR/2.stdin" ] && grep -q "PREVIOUS ATTEMPT AT THIS PHASE FAILED" "$FAKE_AGENT_LOG_DIR/2.stdin"' "$(grep loop "$FD/status.md")"
t_begin "ends INCOMPLETE with P1 blocked and listed in QA.md section 2"; assert 'grep -q "^result=INCOMPLETE" "$FD/.runinfo" && [ "$(state_of "$FD" P1)" = blocked ] && sed -n "/^## 2/,/^## 3/p" "$FD/QA.md" | grep -q "P1"' "$(cat "$FD/QA.md")"
t_begin "AUDIT still ran on the INCOMPLETE ending"; assert 'ls "$FD"/audit-*.md >/dev/null 2>&1'
rm_sandbox

# ─────────────────────────────────────────────────────────────────────────────
echo "-- 3. kimi adapter: prompt as argument (legacy transport)"
mk_sandbox
PR="$SANDBOX/kimi repo"; make_repo "$PR"; make_feature "$PR" feat-k $'P1|—|'
FD="$PR/docs/features/feat-k"; render_loop "$FD" feat-k "$PR"
printf 'P1=done\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"
run_loop "$FD" AGENT=kimi MAX_PARALLEL=1
t_begin "kimi -p <prompt> with prompt embedded in argv"; assert '[ "$(sed -n 1p "$FAKE_AGENT_LOG_DIR/1.argv")" = kimi ] && [ "$(sed -n 2p "$FAKE_AGENT_LOG_DIR/1.argv")" = -p ] && grep -q "one phase (P1)" "$FAKE_AGENT_LOG_DIR/1.argv"'
t_begin "unknown agent refused"; ( cd "$FD" && AGENT=foo "$BASH_BIN" ./loop.sh > /dev/null 2>&1 ); assert '[ $? -ne 0 ]'
rm_sandbox

# ─────────────────────────────────────────────────────────────────────────────
echo "-- 4. gates, retries, qa-pending dependency semantics, STRICT_DEPS"
mk_sandbox
PR="$SANDBOX/repo"; make_repo "$PR"
make_feature "$PR" feat-g $'P1|—|GATE:test -f work/gate-ok-P1\nP2|P1|QA:open /x and see one row\nP3|P2|GATE:false\nP4|P3|'
FD="$PR/docs/features/feat-g"; render_loop "$FD" feat-g "$PR"
printf 'P1=done-flaky\nP2=qa-pending:needs a human eye on /x\nP3=done\nP4=done\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"
run_loop "$FD" AGENT=claude MAX_PARALLEL=1
t_begin "gate ran BY THE LOOP: first attempt revoked (gate red), retry passed"; assert 'grep -q "P1 gate FAILED (attempt 1)" "$FD/status.md" && grep -q "P1 done — gate passed" "$FD/status.md" && [ "$(state_of "$FD" P1)" = done ]' "$(grep loop "$FD/status.md")"
t_begin "retry prompt carried the gate evidence"; assert 'grep -q "gate command failed" "$FAKE_AGENT_LOG_DIR/2.stdin"'
t_begin "qa-pending P2 satisfied P3's dependency (P3 ran)"; assert 'grep -q "one phase (P3)" "$FAKE_AGENT_LOG_DIR/3.stdin" || grep -q "one phase (P3)" "$FAKE_AGENT_LOG_DIR/4.stdin"'
t_begin "P3 gate 'false' fails twice → blocked defect; P4 swept forward over it (degraded notice)"; assert '[ "$(state_of "$FD" P3)" = blocked ] && grep -q "forward sweep: dispatching P4" "$FD/status.md" && grep -l "DEGRADED DEPENDENCY NOTICE" "$FAKE_AGENT_LOG_DIR"/*.stdin >/dev/null' "$(grep loop "$FD/status.md")"
t_begin "QA.md: P2 in section 1 with its QA line; P3 in section 2; P1/P4 in section 4"; assert 'sed -n "/^## 1/,/^## 2/p" "$FD/QA.md" | grep -q "P2" && sed -n "/^## 1/,/^## 2/p" "$FD/QA.md" | grep -q "QA: open /x" && sed -n "/^## 2/,/^## 3/p" "$FD/QA.md" | grep -q "P3" && sed -n "/^## 4/,\$p" "$FD/QA.md" | grep -q "P1" && sed -n "/^## 4/,\$p" "$FD/QA.md" | grep -q "P4"' "$(cat "$FD/QA.md")"
t_begin "run is INCOMPLETE (a defect remains) and qa_items counted"; assert 'grep -q "^result=INCOMPLETE" "$FD/.runinfo" && grep -q "^qa_items=" "$FD/.runinfo"'
# STRICT_DEPS=1: qa-pending must NOT satisfy
rm -rf "$FAKE_AGENT_LOG_DIR"/*; make_feature "$PR" feat-s $'P1|—|\nP2|P1|'; FD="$PR/docs/features/feat-s"; render_loop "$FD" feat-s "$PR"
printf 'P1=qa-pending:check it\nP2=done\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"
run_loop "$FD" AGENT=claude MAX_PARALLEL=1 STRICT_DEPS=1 FORCE_FORWARD=0
t_begin "STRICT_DEPS=1 FORCE_FORWARD=0: P2 never ran behind a qa-pending P1"; assert '[ "$(state_of "$FD" P2)" = todo ] && ! grep -l "one phase (P2)" "$FAKE_AGENT_LOG_DIR"/*.stdin >/dev/null 2>&1' "$(grep loop "$FD/status.md")"
t_begin "STRICT_DEPS=1 default FORCE_FORWARD: P2 is swept forward"; rm -rf "$FAKE_AGENT_LOG_DIR"/*; python3 - "$FD/status.md" <<'PY'
import re,sys; p=sys.argv[1]; s=open(p).read(); s=re.sub(r'^(\| *P1 *\| *)[^|]*(\|)',r'\g<1>todo \g<2>',s,count=1,flags=re.M); open(p,'w').write(s)
PY
run_loop "$FD" AGENT=claude MAX_PARALLEL=1 STRICT_DEPS=1; assert '[ "$(state_of "$FD" P2)" = done ] && grep -q "forward sweep: dispatching P2" "$FD/status.md"' "$(grep loop "$FD/status.md")"
rm_sandbox

# ─────────────────────────────────────────────────────────────────────────────
echo "-- 5. HUMAN-ONLY, at-keyboard attempt/defer, wave parallelism, lanes"
mk_sandbox
PR="$SANDBOX/repo"; make_repo "$PR"
WAVES=$'| 1 | P1 |\n| 2 | P2, P3 |\n| 3 | P4, P5 |'; make_feature "$PR" feat-h $'P1|—|\nP2|P1|LANE:build\nP3|P1|LANE:build\nP4|P2|HUMAN-ONLY:flips the production flag;OWNER:open the console\nP5|P3|OWNER:plug the phone in;QA:tap the button'
FD="$PR/docs/features/feat-h"; ATK="P5"; render_loop "$FD" feat-h "$PR"
printf 'P1=done\nP2=done\nP3=done\nP4=done\nP5=done\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"
export FAKE_AGENT_SLEEP=2
run_loop "$FD" AGENT=codex MAX_PARALLEL=3
unset FAKE_AGENT_SLEEP
t_begin "HUMAN-ONLY P4 never attempted"; assert '[ "$(state_of "$FD" P4)" = todo ] && ! grep -l "one phase (P4)" "$FAKE_AGENT_LOG_DIR"/*.stdin >/dev/null 2>&1'
t_begin "at-keyboard P5 attempted with the supervised notice and downgraded to qa-pending"; assert 'grep -l "UNATTENDED ATTEMPT OF A SUPERVISED PHASE" "$FAKE_AGENT_LOG_DIR"/*.stdin >/dev/null && [ "$(state_of "$FD" P5)" = qa-pending ]' "$(grep loop "$FD/status.md")"
t_begin "P5's OWNER line was embedded in its prompt"; assert 'grep -l "plug the phone in" "$FAKE_AGENT_LOG_DIR"/*.stdin >/dev/null'
t_begin "QA.md section 3 has P4 with HUMAN-ONLY reason + owner line; section 1 has P5 with QA + OWNER"; assert 'sed -n "/^## 3/,/^## 4/p" "$FD/QA.md" | grep -q "flips the production flag" && sed -n "/^## 3/,/^## 4/p" "$FD/QA.md" | grep -q "OWNER: open the console" && sed -n "/^## 1/,/^## 2/p" "$FD/QA.md" | grep -q "QA: tap the button" && sed -n "/^## 1/,/^## 2/p" "$FD/QA.md" | grep -q "OWNER: plug the phone in"' "$(cat "$FD/QA.md")"
t_begin "lanes: P2 and P3 share lane build → never in flight together"; assert '! grep -q "in flight: P2 P3" "$FD/run.out" && ! grep -q "in flight: P3 P2" "$FD/run.out"' "$(grep dispatched "$FD/run.out")"
t_begin "COMPLETE? no — HUMAN-ONLY P4 remains todo → INCOMPLETE, and it is not in section 2"; assert 'grep -q "^result=INCOMPLETE" "$FD/.runinfo" && ! sed -n "/^## 2/,/^## 3/p" "$FD/QA.md" | grep -q "P4"'
# wave concurrency without lanes
rm -rf "$FAKE_AGENT_LOG_DIR"/*
WAVES=$'| 1 | P1 |\n| 2 | P2, P3 |'; make_feature "$PR" feat-w $'P1|—|\nP2|P1|\nP3|P1|'
FD="$PR/docs/features/feat-w"; render_loop "$FD" feat-w "$PR"; printf 'P1=done\nP2=done\nP3=done\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"
export FAKE_AGENT_SLEEP=3; run_loop "$FD" AGENT=claude MAX_PARALLEL=3; unset FAKE_AGENT_SLEEP
t_begin "wave 2: P2 and P3 in flight together, concurrency notice in prompts"; assert 'grep -qE "in flight: P2 P3|in flight: P3 P2" "$FD/run.out" && grep -l "CONCURRENT RUN NOTICE" "$FAKE_AGENT_LOG_DIR"/*.stdin >/dev/null' "$(grep dispatched "$FD/run.out")"
# defer mode
rm -rf "$FAKE_AGENT_LOG_DIR"/*
make_feature "$PR" feat-d $'P1|—|\nP2|P1|OWNER:do it yourself'; FD="$PR/docs/features/feat-d"; ATK="P2"; render_loop "$FD" feat-d "$PR"
printf 'P1=done\nP2=done\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"; run_loop "$FD" AGENT=claude AT_KEYBOARD_MODE=defer
t_begin "AT_KEYBOARD_MODE=defer routes around P2 → QA.md section 3"; assert '[ "$(state_of "$FD" P2)" = todo ] && sed -n "/^## 3/,/^## 4/p" "$FD/QA.md" | grep -q "P2" && sed -n "/^## 3/,/^## 4/p" "$FD/QA.md" | grep -q "OWNER: do it yourself"' "$(cat "$FD/QA.md")"
rm_sandbox

# ─────────────────────────────────────────────────────────────────────────────
echo "-- 6. watchdog, rate-limit brake, clobber repair, stale in-progress reset"
mk_sandbox
PR="$SANDBOX/repo"; make_repo "$PR"
make_feature "$PR" feat-t $'P1|—|'; FD="$PR/docs/features/feat-t"; render_loop "$FD" feat-t "$PR"
printf 'P1=sleep:60\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"
run_loop "$FD" AGENT=claude PHASE_TIMEOUT_SEC=3 MAX_RETRIES=0
t_begin "watchdog killed a wedged agent (timeout noted, blocked)"; assert 'grep -q "watchdog timeout" "$FD/status.md" && [ "$(state_of "$FD" P1)" = blocked ]' "$(grep loop "$FD/status.md"; cat "$FD/run.out")"
# rate limit: first call hits the limit → pause file written → row reset → retried without consuming a retry
rm -rf "$FAKE_AGENT_LOG_DIR"/*; make_feature "$PR" feat-r $'P1|—|'; FD="$PR/docs/features/feat-r"; render_loop "$FD" feat-r "$PR"
cat > "$SANDBOX/bin/claude" <<EOF
#!/usr/bin/env bash
# first PHASE call answers with a rate-limit error; --version / auth status pass through
case "\${1:-}" in --version|-v|auth|login) exec -a claude "$FIXTURES/bin/fake-agent" "\$@" ;; esac
if [ ! -f "\$FAKE_AGENT_LOG_DIR/.limited" ]; then
  : > "\$FAKE_AGENT_LOG_DIR/.limited"; cat >/dev/null
  echo "Error: rate limit reached, resets at 5pm"; exit 1
fi
exec -a claude "$FIXTURES/bin/fake-agent" "\$@"
EOF
chmod +x "$SANDBOX/bin/claude"
printf 'P1=done\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"
run_loop "$FD" AGENT=claude LIMIT_BACKOFF_MIN=0 MAX_RETRIES=0
t_begin "rate limit: fleet paused, row reset, phase completed on the same attempt budget"; assert 'grep -q "fleet paused" "$FD/status.md" && [ "$(state_of "$FD" P1)" = done ]' "$(grep loop "$FD/status.md")"
cp "$FIXTURES/bin/fake-agent" "$SANDBOX/bin/claude"
# clobber repair: P2 rewrites P1's row to todo after the loop confirmed it done
rm -rf "$FAKE_AGENT_LOG_DIR"/*; make_feature "$PR" feat-cl $'P1|—|\nP2|P1|'; FD="$PR/docs/features/feat-cl"; render_loop "$FD" feat-cl "$PR"
printf 'P1=done\nP2=done-clobber\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"; run_loop "$FD" AGENT=claude
t_begin "clobber repair restored P1 to done"; assert 'grep -q "repaired P1" "$FD/status.md" && [ "$(state_of "$FD" P1)" = done ] && grep -q "^result=COMPLETE" "$FD/.runinfo"' "$(grep loop "$FD/status.md")"
# stale in-progress reset
rm -rf "$FAKE_AGENT_LOG_DIR"/*; make_feature "$PR" feat-st $'P1|—|\nP2|P1|'; FD="$PR/docs/features/feat-st"; render_loop "$FD" feat-st "$PR"
sed -i.bak 's/^| P1 | todo/| P1 | in-progress/' "$FD/status.md"; printf 'P2=done\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"; run_loop "$FD" AGENT=claude
t_begin "stale in-progress P1 reset to blocked at startup (never built on)"; assert 'grep -q "reset stale in-progress P1" "$FD/status.md" && [ "$(state_of "$FD" P1)" = blocked ]'
rm_sandbox

# ─────────────────────────────────────────────────────────────────────────────
echo "-- 7. preflight is side-effect-free; nested launch refused; double start refused"
mk_sandbox
PR="$SANDBOX/repo"; make_repo "$PR"
make_feature "$PR" feat-p $'P1|—|GATE:true\nP2|P1|HUMAN-ONLY:live payment;OWNER:have the card ready\nP3|P1|QA:see the row'
FD="$PR/docs/features/feat-p"; ATK="P3"; render_loop "$FD" feat-p "$PR"
printf 'version=2.1.100\n' > "$FAKE_AGENT_SCRIPT"
BEFORE="$(tree_hash "$FD")"
( cd "$FD" && AGENT=claude "$BASH_BIN" ./loop.sh --preflight ) > "$SANDBOX/pf.out" 2>&1; PF_RC=$?
AFTER="$(tree_hash "$FD")"
t_begin "preflight exits 0 and prints agent argv, repos, HUMAN-ONLY, at-keyboard, QA, gates"; assert '[ $PF_RC = 0 ] && grep -q "argv: claude -p" "$SANDBOX/pf.out" && grep -q "live payment" "$SANDBOX/pf.out" && grep -q "have the card ready" "$SANDBOX/pf.out" && grep -q "P3: see the row" "$SANDBOX/pf.out" && grep -q "P1: true" "$SANDBOX/pf.out" && grep -q "claude authenticated" "$SANDBOX/pf.out"' "$(cat "$SANDBOX/pf.out")"
t_begin "preflight: no --permission-prompts for old Claude (2.1.100 < 2.1.259)"; assert '! grep -q "permission-prompts" "$SANDBOX/pf.out"'
t_begin "preflight did not mutate the feature folder (no .run, no .runinfo, no logs, status.md untouched)"; assert '[ "$BEFORE" = "$AFTER" ] && [ ! -d "$FD/.run" ] && [ ! -f "$FD/.runinfo" ] && [ ! -d "$FD/logs" ]'
t_begin "preflight with a missing extra repo warns instead of failing"; ( cd "$FD" && LOOP_EXTRA_REPOS="/nonexistent dir" AGENT=codex "$BASH_BIN" ./loop.sh --preflight ) > "$SANDBOX/pf2.out" 2>&1; assert 'grep -q "missing" "$SANDBOX/pf2.out" && grep -q "argv: codex exec" "$SANDBOX/pf2.out"' "$(cat "$SANDBOX/pf2.out")"
t_begin "nested guard: loop.sh refuses to start with LOOP_PILOT_NESTED=1 (exit 3, nothing written)"; ( cd "$FD" && LOOP_PILOT_NESTED=1 AGENT=claude "$BASH_BIN" ./loop.sh ) > "$SANDBOX/nest.out" 2>&1; RC=$?; assert '[ $RC = 3 ] && [ ! -f "$FD/.runinfo" ]' "$(cat "$SANDBOX/nest.out")"
t_begin "double start refused while a loop is alive (exit 4), and the live loop's .run is untouched"
printf 'P1=sleep:6\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"
( cd "$FD" && AGENT=claude "$BASH_BIN" ./loop.sh > "$FD/bg.out" 2>&1 ) & BG=$!
sleep 3
( cd "$FD" && AGENT=claude "$BASH_BIN" ./loop.sh ) > "$SANDBOX/dbl.out" 2>&1; RC2=$?
( cd "$FD" && AGENT=claude "$BASH_BIN" ./loop.sh --preflight ) > /dev/null 2>&1
RUN_STILL="$( [ -d "$FD/.run" ] && echo yes || echo no )"
wait $BG
assert '[ $RC2 = 4 ] && [ "$RUN_STILL" = yes ]' "$(cat "$SANDBOX/dbl.out")"
rm_sandbox

t_summary
