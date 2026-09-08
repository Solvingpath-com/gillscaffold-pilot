#!/usr/bin/env bash
# Installer tests — every one runs against a temporary HOME whose path contains a space.
set -o pipefail
. "$(dirname "$0")/lib.sh"
echo "== installer tests"
INSTALL="$REPO_ROOT/install.sh"
UNINSTALL="$REPO_ROOT/uninstall.sh"

echo "-- 1. fresh install for both agents"
mk_sandbox
"$BASH_BIN" "$INSTALL" --all --quiet > "$SANDBOX/i1.out" 2>&1; RC=$?
t_begin "exits 0"; assert '[ $RC = 0 ]' "$(cat "$SANDBOX/i1.out")"
t_begin "claude target populated"; assert '[ -f "$HOME/.claude/skills/grillscaffold/SKILL.md" ] && [ -f "$HOME/.claude/skills/loop-pilot/SKILL.md" ]'
t_begin "codex target is ~/.agents/skills (official), not ~/.codex/skills"; assert '[ -f "$HOME/.agents/skills/loop-pilot/SKILL.md" ] && [ ! -d "$HOME/.codex/skills" ]'
t_begin "scripts are executable"; assert '[ -x "$HOME/.claude/skills/loop-pilot/scripts/launch.sh" ] && [ -x "$HOME/.claude/skills/loop-pilot/scripts/doctor.sh" ] && [ -x "$HOME/.claude/skills/loop-pilot/scripts/render-loop.py" ]'
t_begin "release-manifest.json installed beside each skill"; assert '[ -f "$HOME/.claude/skills/loop-pilot/release-manifest.json" ] && [ -f "$HOME/.agents/skills/grillscaffold/release-manifest.json" ]'
t_begin "both skills carry identical runner templates"; assert 'cmp -s "$HOME/.claude/skills/grillscaffold/references/loop-template.md" "$HOME/.claude/skills/loop-pilot/references/loop-template.md"'
t_begin "--verify passes on a fresh install"; "$BASH_BIN" "$INSTALL" --verify > "$SANDBOX/v1.out" 2>&1; RCV=$?; assert '[ $RCV = 0 ] && grep -q "identical runner template" "$SANDBOX/v1.out"' "$(cat "$SANDBOX/v1.out")"
t_begin "installed skill can render a runner (end-to-end usability)"
mkdir -p "$SANDBOX/r/docs/features/x"
python3 "$HOME/.claude/skills/loop-pilot/scripts/render-loop.py" --template "$HOME/.claude/skills/loop-pilot/references/loop-template.md" --feature x --primary "$SANDBOX/r" --out "$SANDBOX/r/loop.sh" 2>"$SANDBOX/render.err"
assert '[ -s "$SANDBOX/r/loop.sh" ] && "$BASH_BIN" -n "$SANDBOX/r/loop.sh"' "$(cat "$SANDBOX/render.err")"

echo "-- 2. idempotence and upgrade-in-place"
BEFORE="$(tree_hash "$HOME/.claude/skills/loop-pilot")"
"$BASH_BIN" "$INSTALL" --all --quiet > "$SANDBOX/i2.out" 2>&1
t_begin "re-install is a no-op for content"; assert '[ "$BEFORE" = "$(tree_hash "$HOME/.claude/skills/loop-pilot")" ]'
t_begin "re-install backs up the replaced copy"; assert 'ls -d "$HOME/.claude/skills/.loop-pilot-backups/loop-pilot-"* >/dev/null 2>&1'
# simulate an older install and upgrade over it
rm -rf "$HOME/.claude/skills/loop-pilot"
mkdir -p "$HOME/.claude/skills/loop-pilot/scripts"
printf -- '---\nname: loop-pilot\nversion: 7.0.0\n---\nold\n' > "$HOME/.claude/skills/loop-pilot/SKILL.md"
echo "stale" > "$HOME/.claude/skills/loop-pilot/scripts/obsolete.sh"
"$BASH_BIN" "$INSTALL" --claude --quiet > "$SANDBOX/i3.out" 2>&1
t_begin "upgrade from an older version replaces it wholesale (no stale files left)"; assert 'grep -q "version: 8" "$HOME/.claude/skills/loop-pilot/SKILL.md" && [ ! -f "$HOME/.claude/skills/loop-pilot/scripts/obsolete.sh" ]'
t_begin "the old version is preserved in backups"; assert 'ls -d "$HOME/.claude/skills/.loop-pilot-backups/loop-pilot-7.0.0-"* >/dev/null 2>&1' "$(ls "$HOME/.claude/skills/.loop-pilot-backups" 2>/dev/null)"
rm_sandbox

echo "-- 3. single-agent installs and dry run"
mk_sandbox
"$BASH_BIN" "$INSTALL" --claude --quiet > /dev/null 2>&1
t_begin "--claude installs only the Claude target"; assert '[ -d "$HOME/.claude/skills/loop-pilot" ] && [ ! -d "$HOME/.agents/skills" ]'
rm_sandbox
mk_sandbox
"$BASH_BIN" "$INSTALL" --codex --quiet > /dev/null 2>&1
t_begin "--codex installs only the Codex target"; assert '[ -d "$HOME/.agents/skills/loop-pilot" ] && [ ! -d "$HOME/.claude/skills" ]'
t_begin "--verify --claude fails when Claude has nothing"; "$BASH_BIN" "$INSTALL" --verify --claude > "$SANDBOX/v2.out" 2>&1; RCV2=$?; assert '[ $RCV2 != 0 ] && grep -q "not installed" "$SANDBOX/v2.out"'
rm_sandbox
mk_sandbox
"$BASH_BIN" "$INSTALL" --all --dry-run > "$SANDBOX/d.out" 2>&1
t_begin "--dry-run writes nothing and says what it would do"; assert '[ ! -d "$HOME/.claude/skills" ] && [ ! -d "$HOME/.agents/skills" ] && grep -q "would INSTALL" "$SANDBOX/d.out"' "$(cat "$SANDBOX/d.out")"

echo "-- 4. it never eats someone else's skill"
mkdir -p "$HOME/.claude/skills/loop-pilot"
printf -- '---\nname: someone-elses-thing\n---\nmine\n' > "$HOME/.claude/skills/loop-pilot/SKILL.md"
"$BASH_BIN" "$INSTALL" --claude > "$SANDBOX/i4.out" 2>&1; RC=$?
t_begin "refuses to overwrite a directory that is not our skill"; assert '[ $RC != 0 ] && grep -q "NOT our skill" "$SANDBOX/i4.out" && grep -q someone-elses-thing "$HOME/.claude/skills/loop-pilot/SKILL.md"' "$(cat "$SANDBOX/i4.out")"
t_begin "grillscaffold still installed alongside the refusal"; assert '[ -f "$HOME/.claude/skills/grillscaffold/SKILL.md" ]'
rm_sandbox

echo "-- 5. install from a built archive (the exact path a GitHub release takes)"
mk_sandbox
"$BASH_BIN" "$REPO_ROOT/scripts/package-release.sh" > "$SANDBOX/pkg.out" 2>&1
t_begin "package-release.sh produces an archive and checksums"; assert '[ -f "$REPO_ROOT/dist/grillscaffold-loop-pilot.tar.gz" ] && [ -s "$REPO_ROOT/dist/SHA256SUMS" ]' "$(cat "$SANDBOX/pkg.out")"
mkdir -p "$SANDBOX/x" && tar -xzf "$REPO_ROOT/dist/grillscaffold-loop-pilot.tar.gz" -C "$SANDBOX/x"
t_begin "the archive's own install.sh installs from inside the archive"
"$BASH_BIN" "$SANDBOX/x/grillscaffold-loop-pilot/install.sh" --all --quiet > "$SANDBOX/i5.out" 2>&1; RC5=$?
assert '[ $RC5 = 0 ] && [ -f "$HOME/.claude/skills/loop-pilot/references/loop-template.md" ]' "$(cat "$SANDBOX/i5.out")"
t_begin "--from <archive> installs too"; rm -rf "$HOME/.agents/skills"
"$BASH_BIN" "$INSTALL" --codex --quiet --from "$REPO_ROOT/dist/grillscaffold-loop-pilot.tar.gz" > "$SANDBOX/i6.out" 2>&1; RC6=$?
assert '[ $RC6 = 0 ] && [ -f "$HOME/.agents/skills/loop-pilot/SKILL.md" ]' "$(cat "$SANDBOX/i6.out")"
t_begin "an incomplete package is refused before anything is touched"
rm -rf "$SANDBOX/bad"; cp -R "$SANDBOX/x/grillscaffold-loop-pilot" "$SANDBOX/bad"; rm -f "$SANDBOX/bad/skills/loop-pilot/SKILL.md"
"$BASH_BIN" "$INSTALL" --claude --from "$SANDBOX/bad" > "$SANDBOX/i7.out" 2>&1; RC7=$?
assert '[ $RC7 != 0 ] && grep -q "incomplete" "$SANDBOX/i7.out"' "$(cat "$SANDBOX/i7.out")"
t_begin "a package whose two templates disagree is refused"
rm -rf "$SANDBOX/bad2"; cp -R "$SANDBOX/x/grillscaffold-loop-pilot" "$SANDBOX/bad2"
echo "drift" >> "$SANDBOX/bad2/skills/grillscaffold/references/loop-template.md"
"$BASH_BIN" "$INSTALL" --claude --from "$SANDBOX/bad2" > "$SANDBOX/i8.out" 2>&1; RC8=$?
assert '[ $RC8 != 0 ] && grep -q "differ" "$SANDBOX/i8.out"' "$(cat "$SANDBOX/i8.out")"

echo "-- 5b. a repository with no published release fails clearly, not cryptically"
mk_sandbox
# run a COPY with no sibling skills/ dir, so the installer takes the download path
cp "$INSTALL" "$SANDBOX/install-standalone.sh"; cp "$REPO_ROOT/VERSION" "$SANDBOX/VERSION"
( cd "$SANDBOX" && LOOP_PILOT_REPO="Solvingpath-com/definitely-not-a-real-repo-$$" "$BASH_BIN" ./install-standalone.sh --claude ) > "$SANDBOX/nr.out" 2>&1; RCN=$?
t_begin "explains that no release exists and names the branch fallback"
assert '[ $RCN != 0 ] && grep -q "no release asset" "$SANDBOX/nr.out" && grep -q "LOOP_PILOT_REF=main" "$SANDBOX/nr.out"' "$(cat "$SANDBOX/nr.out")"
t_begin "does not leak download progress into the error (the \$SRC capture bug)"
assert '! grep -q "no source tree found (looked in.*downloading" "$SANDBOX/nr.out"' "$(cat "$SANDBOX/nr.out")"
t_begin "wrote nothing to the skills directories"; assert '[ ! -d "$HOME/.claude/skills/loop-pilot" ]'
rm_sandbox
mk_sandbox
tar -xzf "$REPO_ROOT/dist/grillscaffold-loop-pilot.tar.gz" -C "$SANDBOX" 2>/dev/null || "$BASH_BIN" "$REPO_ROOT/scripts/package-release.sh" >/dev/null 2>&1
"$BASH_BIN" "$INSTALL" --all --quiet --from "$REPO_ROOT/dist/grillscaffold-loop-pilot.tar.gz" >/dev/null 2>&1

echo "-- 6. uninstall"
t_begin "--dry-run removes nothing"; "$BASH_BIN" "$UNINSTALL" --all --dry-run > "$SANDBOX/u0.out" 2>&1; assert '[ -d "$HOME/.claude/skills/loop-pilot" ] && grep -q "would remove" "$SANDBOX/u0.out"'
"$BASH_BIN" "$UNINSTALL" --all > "$SANDBOX/u1.out" 2>&1
t_begin "removes both skills from both targets"; assert '[ ! -d "$HOME/.claude/skills/loop-pilot" ] && [ ! -d "$HOME/.claude/skills/grillscaffold" ] && [ ! -d "$HOME/.agents/skills/loop-pilot" ]'
t_begin "leaves a foreign skill alone"; mkdir -p "$HOME/.claude/skills/other"; printf -- '---\nname: other\n---\n' > "$HOME/.claude/skills/other/SKILL.md"
"$BASH_BIN" "$UNINSTALL" --all > /dev/null 2>&1; assert '[ -f "$HOME/.claude/skills/other/SKILL.md" ]'
t_begin "--purge-state removes ~/.loop-pilot only when asked"
mkdir -p "$LOOP_PILOT_STATE"; echo x > "$LOOP_PILOT_STATE/repos.txt"
"$BASH_BIN" "$UNINSTALL" --all > /dev/null 2>&1
keep=$([ -f "$LOOP_PILOT_STATE/repos.txt" ] && echo yes || echo no)
"$BASH_BIN" "$UNINSTALL" --all --purge-state > /dev/null 2>&1
assert '[ "$keep" = yes ] && [ ! -d "$LOOP_PILOT_STATE" ]'
rm_sandbox
rm -rf "$REPO_ROOT/dist"

t_summary
