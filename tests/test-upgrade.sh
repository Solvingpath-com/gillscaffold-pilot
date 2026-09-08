#!/usr/bin/env bash
# upgrade.sh tests — a feature scaffolded by an OLD grillscaffold must become a current
# A→Z runner without losing its own configuration.
set -o pipefail
. "$(dirname "$0")/lib.sh"
echo "== upgrade tests"
UPG="$REPO_ROOT/skills/loop-pilot/scripts/upgrade.sh"

mk_sandbox
PR="$SANDBOX/my repo"; E1="$SANDBOX/api repo"; make_repo "$PR"; mkdir -p "$E1"
EXTRA_REPO_LIST=("$E1"); make_feature "$PR" old-feat $'P1|—|\nP2|P1|OWNER:plug in a device\nP3|P2|'
FD="$PR/docs/features/old-feat"

# a v0 runner: the pre-parallel, stops-for-a-human generation, with its own config baked in
cat > "$FD/loop.sh" <<EOF
#!/usr/bin/env bash
# grillscaffold unattended runner — old-feat
set -uo pipefail
FEATURE="old-feat"
PRIMARY_REPO="$PR"
EXTRA_REPOS=('$E1')
AT_KEYBOARD=(P2)
echo "old runner: writes handoff.md and exits when it meets a human step"
EOF
chmod +x "$FD/loop.sh"

echo "-- 1. verdicts"
"$BASH_BIN" "$UPG" "$FD" --check > "$SANDBOX/c1.out" 2>&1; RC=$?
t_begin "--check reports OUTDATED-contract for a pre-v4 runner and exits 3"; assert '[ $RC = 3 ] && grep -q "OUTDATED-contract" "$SANDBOX/c1.out"' "$(cat "$SANDBOX/c1.out")"
t_begin "--check changed nothing"; assert 'grep -q "old runner" "$FD/loop.sh"'

echo "-- 2. the upgrade itself"
"$BASH_BIN" "$UPG" "$FD" > "$SANDBOX/u1.out" 2>&1; RC=$?
t_begin "exits 0 and says what it did"; assert '[ $RC = 0 ] && grep -q "UPGRADED" "$SANDBOX/u1.out"' "$(cat "$SANDBOX/u1.out")"
t_begin "the new runner is template v5 and passes a syntax check"; assert 'grep -q "^# template-version: 5" "$FD/loop.sh" && "$BASH_BIN" -n "$FD/loop.sh"'
t_begin "primary repo preserved (path has a space)"; assert 'grep -qF "PRIMARY_REPO=\"$PR\"" "$FD/loop.sh"' "$(grep PRIMARY_REPO "$FD/loop.sh")"
t_begin "extra repo recovered from the old script"; assert 'grep -qF "EXTRA_REPOS=('"'"'$E1'"'"')" "$FD/loop.sh"' "$(grep EXTRA_REPOS "$FD/loop.sh")"
t_begin "at-keyboard phases preserved"; assert 'grep -q "^AT_KEYBOARD=(P2)" "$FD/loop.sh"'
t_begin "a timestamped backup of the old runner exists"; assert 'ls "$FD"/loop.sh.bak-* >/dev/null 2>&1 && grep -q "old runner" "$FD"/loop.sh.bak-*'
t_begin "status.md records the upgrade for the owner"; assert 'grep -q "upgraded loop.sh to template v5" "$FD/status.md"' "$(grep pilot "$FD/status.md")"
t_begin "the upgraded runner actually flies"; printf 'P1=done\nP2=done\nP3=done\nAUDIT=audit\n' > "$FAKE_AGENT_SCRIPT"
( cd "$FD" && AGENT=claude MAX_PARALLEL=1 POLL_SEC=1 "$BASH_BIN" ./loop.sh ) > "$SANDBOX/run.out" 2>&1
assert '[ -f "$FD/QA.md" ] && grep -q "^result=" "$FD/.runinfo"' "$(tail -20 "$SANDBOX/run.out")"

echo "-- 3. idempotence and safety"
"$BASH_BIN" "$UPG" "$FD" > "$SANDBOX/u2.out" 2>&1
t_begin "second run is a no-op (CURRENT)"; assert 'grep -q "CURRENT" "$SANDBOX/u2.out"' "$(cat "$SANDBOX/u2.out")"
t_begin "--check on a current runner exits 0"; "$BASH_BIN" "$UPG" "$FD" --check >/dev/null 2>&1; assert '[ $? = 0 ]'
t_begin "MISSING when there is no loop.sh (exit 2)"; rm -f "$FD/loop.sh"; "$BASH_BIN" "$UPG" "$FD" --check > "$SANDBOX/c2.out" 2>&1; assert '[ $? = 2 ] && grep -q MISSING "$SANDBOX/c2.out"'
t_begin "renders a fresh runner when none exists, recovering repos from prompts.md"
"$BASH_BIN" "$UPG" "$FD" > "$SANDBOX/u3.out" 2>&1
assert '[ -f "$FD/loop.sh" ] && grep -qF "$E1" "$FD/loop.sh"' "$(cat "$SANDBOX/u3.out")"

echo "-- 4. it refuses to swap the runner under a live loop"
printf 'pid=%s\nstarted=1\n' "$$" > "$FD/.runinfo"
BEFORE="$(sha256sum < "$FD/loop.sh")"
"$BASH_BIN" "$UPG" "$FD" > "$SANDBOX/u4.out" 2>&1; RC=$?
t_begin "refuses while a run is alive, and leaves the runner untouched"; assert '[ $RC != 0 ] && grep -q "already running\|is running" "$SANDBOX/u4.out" && [ "$BEFORE" = "$(sha256sum < "$FD/loop.sh")" ]' "$(cat "$SANDBOX/u4.out")"
rm -f "$FD/.runinfo"
rm_sandbox

echo "-- 5. a v3-era runner (route-around, handoff) is treated as contract-outdated"
mk_sandbox
PR="$SANDBOX/repo"; make_repo "$PR"; make_feature "$PR" v3feat $'P1|—|'
FD="$PR/docs/features/v3feat"
{ echo '#!/usr/bin/env bash'; echo '# template-version: 3'; echo 'FEATURE="v3feat"'; echo "PRIMARY_REPO=\"$PR\""
  echo 'EXTRA_REPOS=()'; echo 'AT_KEYBOARD=()'; echo 'write_handoff() { :; }'; echo 'echo routed around'; } > "$FD/loop.sh"
chmod +x "$FD/loop.sh"
"$BASH_BIN" "$UPG" "$FD" --check > "$SANDBOX/c3.out" 2>&1
t_begin "v3 runner reports OUTDATED-contract (no QA.md, stops for a human)"; assert 'grep -q "OUTDATED-contract" "$SANDBOX/c3.out"' "$(cat "$SANDBOX/c3.out")"
"$BASH_BIN" "$UPG" "$FD" > /dev/null 2>&1
t_begin "after upgrade it writes QA.md and honours the A→Z contract"; assert 'grep -q "write_qa" "$FD/loop.sh" && grep -q "^# template-version: 5" "$FD/loop.sh"'
rm_sandbox

t_summary
