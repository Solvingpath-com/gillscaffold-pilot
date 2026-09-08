#!/usr/bin/env bash
# Point the whole repository at a GitHub slug, in one command.
#   scripts/set-github-repo.sh myname/grillscaffold-loop-pilot
set -uo pipefail
NEW="${1:?usage: set-github-repo.sh <owner/repo>}"
case "$NEW" in */*) : ;; *) echo "ERROR: expected owner/repo"; exit 2;; esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OLD="$(grep -oE 'DEFAULT_REPO="[^"]+"' "$ROOT/install.sh" | head -1 | sed 's/.*="//; s/"//')"
[ -n "$OLD" ] || { echo "ERROR: could not read the current slug from install.sh"; exit 1; }
[ "$OLD" = "$NEW" ] && { echo "already set to $NEW"; exit 0; }
FILES="install.sh uninstall.sh README.md CONTRIBUTING.md release-manifest.json skills/loop-pilot/scripts/update.sh skills/loop-pilot/SKILL.md skills/grillscaffold/SKILL.md .github/workflows/release.yml"
n=0
for f in $FILES; do
  [ -f "$ROOT/$f" ] || continue
  if grep -q "$OLD" "$ROOT/$f"; then
    python3 - "$ROOT/$f" "$OLD" "$NEW" <<'PY'
import sys
p,old,new=sys.argv[1:4]
s=open(p,encoding="utf-8").read()
open(p,"w",encoding="utf-8").write(s.replace(old,new))
PY
    echo "  updated $f"; n=$((n+1))
  fi
done
echo "$OLD → $NEW ($n file(s))"
echo "Now run: scripts/check-versions.sh"
