#!/usr/bin/env bash
# Version and consistency gate. CI runs this; run it before every release.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
err() { echo "  ✗ $*"; fail=1; }
ok()  { echo "  ✓ $*"; }

VER="$(tr -d ' \n' < "$ROOT/VERSION")"
MAN_REL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["release"])' "$ROOT/release-manifest.json")"
MAN_GS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["grillscaffold"])' "$ROOT/release-manifest.json")"
MAN_LP="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["loopPilot"])' "$ROOT/release-manifest.json")"
MAN_TPL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["runnerTemplate"])' "$ROOT/release-manifest.json")"
MAN_REPO="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["repository"])' "$ROOT/release-manifest.json")"
GS="$(grep -m1 '^version:' "$ROOT/skills/grillscaffold/SKILL.md" | awk '{print $2}')"
LP="$(grep -m1 '^version:' "$ROOT/skills/loop-pilot/SKILL.md" | awk '{print $2}')"
TPL="$(awk '/^```bash/{f=1;next} f&&/^# *template-version:/{gsub(/[^0-9]/,"",$0);print;exit}' "$ROOT/skills/loop-pilot/references/loop-template.md")"

echo "versions:"
[ "$VER" = "$MAN_REL" ] && ok "VERSION == release-manifest.release ($VER)" || err "VERSION ($VER) != manifest release ($MAN_REL)"
[ "$GS" = "$MAN_GS" ] && ok "grillscaffold SKILL.md == manifest ($GS)" || err "grillscaffold SKILL.md ($GS) != manifest ($MAN_GS)"
[ "$LP" = "$MAN_LP" ] && ok "loop-pilot SKILL.md == manifest ($LP)" || err "loop-pilot SKILL.md ($LP) != manifest ($MAN_LP)"
[ "$TPL" = "$MAN_TPL" ] && ok "runner template v$TPL == manifest" || err "runner template (v$TPL) != manifest ($MAN_TPL)"
grep -q "^## \[\?$VER" "$ROOT/CHANGELOG.md" && ok "CHANGELOG has an entry for $VER" || err "CHANGELOG.md has no '## $VER' entry"

echo "templates:"
if cmp -s "$ROOT/skills/loop-pilot/references/loop-template.md" "$ROOT/skills/grillscaffold/references/loop-template.md"; then
  ok "both skills carry byte-identical loop-template.md"
else err "loop-template.md copies differ — run scripts/sync-templates.sh"; fi

echo "github slug (must be the same everywhere):"
SLUGS="$(grep -oE 'DEFAULT_REPO="[^"]+"' "$ROOT/install.sh" | head -1 | sed 's/.*="//; s/"//')"
[ "$SLUGS" = "$MAN_REPO" ] && ok "install.sh DEFAULT_REPO == manifest repository ($SLUGS)" || err "install.sh ($SLUGS) != manifest repository ($MAN_REPO)"
for f in "$ROOT/README.md" "$ROOT/skills/loop-pilot/scripts/update.sh"; do
  if grep -q "$SLUGS" "$f"; then ok "$(basename "$f") uses $SLUGS"; else err "$(basename "$f") does not mention $SLUGS (run scripts/set-github-repo.sh)"; fi
done

echo "syntax:"
for f in "$ROOT"/*.sh "$ROOT"/scripts/*.sh "$ROOT"/skills/loop-pilot/scripts/*.sh "$ROOT"/tests/*.sh; do
  bash -n "$f" 2>/dev/null || err "bash syntax: $f"
done
for f in "$ROOT"/skills/loop-pilot/scripts/*.py; do
  python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$f" 2>/dev/null || err "python syntax: $f"
done
[ "$fail" = 0 ] && ok "all files parse"
exit $fail
