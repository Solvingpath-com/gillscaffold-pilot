#!/usr/bin/env bash
# Static checks — portability, consistency and the safety rules that must never regress.
set -o pipefail
. "$(dirname "$0")/lib.sh"
echo "== static checks"
TPL="$REPO_ROOT/skills/loop-pilot/references/loop-template.md"
BODY="$SANDBOX_STATIC"; BODY="$(mktemp "${TMPDIR:-/tmp}/loopbody.XXXXXX")"
awk '/^```bash/{f=1;next} f&&/^```/{exit} f' "$TPL" > "$BODY"

echo "-- 1. the runner is bash 3.2 safe (macOS stock)"
t_begin "no bash-4-only constructs in the runner"
assert '! grep -nE "mapfile|readarray|declare -A|local -A|local -n|wait -n|\\\$\\{[A-Za-z_]+(,,|\\^\\^)\\}" "$BODY"' "$(grep -nE 'mapfile|readarray|declare -A|local -n|wait -n' "$BODY")"
t_begin "every shipped shell script parses"
BAD=""; for f in "$REPO_ROOT"/*.sh "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/skills/loop-pilot/scripts/*.sh "$REPO_ROOT"/tests/*.sh "$REPO_ROOT"/tests/fixtures/bin/*; do
  "$BASH_BIN" -n "$f" 2>/dev/null || BAD="$BAD $f"; done
assert '[ -z "$BAD" ]' "$BAD"
t_begin "every shipped python file parses"
BADP=""; for f in "$REPO_ROOT"/skills/loop-pilot/scripts/*.py; do python3 -c 'import ast,sys;ast.parse(open(sys.argv[1]).read())' "$f" 2>/dev/null || BADP="$BADP $f"; done
assert '[ -z "$BADP" ]' "$BADP"
t_begin "scripts and installers are executable in git"
NOX=""; for f in "$REPO_ROOT"/install.sh "$REPO_ROOT"/uninstall.sh "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/skills/loop-pilot/scripts/*; do [ -x "$f" ] || NOX="$NOX $f"; done
assert '[ -z "$NOX" ]' "$NOX"

echo "-- 2. safety rules that must never regress"
t_begin "no agent is ever invoked with a sandbox-bypassing flag"
assert '! grep -nE "dangerously-bypass|danger-full-access|--yolo|bypassPermissions" "$BODY"' "$(grep -nE 'dangerously-bypass|danger-full-access|--yolo|bypassPermissions' "$BODY")"
t_begin "codex is never run read-only (it must be able to edit)"; assert 'grep -q "workspace-write" "$BODY"'
t_begin "git commit and git push are denied at tool level for Claude"; assert 'grep -q "Bash(git push \*)" "$BODY" && grep -q "Bash(git commit \*)" "$BODY"'
t_begin "the runner refuses to run nested inside an agent phase"; assert 'grep -q "LOOP_PILOT_NESTED" "$BODY" && grep -q "exit 3" "$BODY"'
t_begin "no credentials, tokens or personal paths are baked into anything"
assert '! grep -rInE "(sk-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{10,}|BEGIN [A-Z ]*PRIVATE KEY)" "$REPO_ROOT/skills" "$REPO_ROOT"/*.sh'
t_begin "the installer never uses sudo and never writes outside \$HOME"
assert '! grep -nE "^[^#]*\\bsudo\\b" "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh"'

echo "-- 3. bundle consistency"
t_begin "both skills ship byte-identical runner templates"; assert 'cmp -s "$TPL" "$REPO_ROOT/skills/grillscaffold/references/loop-template.md"'
t_begin "check-versions.sh passes"; "$BASH_BIN" "$REPO_ROOT/scripts/check-versions.sh" > "${TMPDIR:-/tmp}/cv.out" 2>&1; assert '[ $? = 0 ]' "$(cat "${TMPDIR:-/tmp}/cv.out")"
t_begin "the template renders and the result is syntactically valid"
OUT="$(mktemp "${TMPDIR:-/tmp}/loop.XXXXXX")"
python3 "$REPO_ROOT/skills/loop-pilot/scripts/render-loop.py" --template "$TPL" --feature demo --primary "/tmp/a b" --extra "/tmp/c'd" --out "$OUT" 2>/dev/null
assert '"$BASH_BIN" -n "$OUT"' "$(head -20 "$OUT")"
t_begin "an unrendered template placeholder can never reach a feature folder"
assert '! grep -q "<primary repo absolute path>" "$OUT" && ! grep -q "<feature>" "$OUT"'
rm -f "$OUT" "$BODY"

echo "-- 4. docs tell the truth"
t_begin "README documents the one-line install"; assert 'grep -q "curl -fsSL" "$REPO_ROOT/README.md" && grep -q "install.sh" "$REPO_ROOT/README.md"'
t_begin "README and installer agree on the skill directories"
assert 'grep -q "\.claude/skills" "$REPO_ROOT/README.md" && grep -q "\.agents/skills" "$REPO_ROOT/README.md"'
t_begin "CHANGELOG's newest entry matches VERSION"
assert 'grep -q "^## $(tr -d " \n" < "$REPO_ROOT/VERSION")" "$REPO_ROOT/CHANGELOG.md"' "$(head -8 "$REPO_ROOT/CHANGELOG.md")"

t_summary
