#!/usr/bin/env bash
# loop-pilot update — fetch and install the latest (or a pinned) release of the
# grillscaffold + loop-pilot bundle, into whichever agents already have it.
#
# Usage:
#   update.sh                 update to the latest release
#   update.sh --version v8.2.0    install a specific tag
#   update.sh --check         report installed vs latest, change nothing
#
# Env: LOOP_PILOT_REPO=owner/repo   override the source repository
set -uo pipefail
REPO="${LOOP_PILOT_REPO:-OWNER/REPO}"
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SDIR/.." && pwd)"

installed() {
  local m="$SKILL_DIR/release-manifest.json"
  [ -f "$m" ] && python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["release"])' "$m" 2>/dev/null || echo "unknown"
}
latest() { curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["tag_name"])
except Exception: print("")' ; }

case "${1:-}" in
  --check)
    l="$(latest)"
    echo "installed: $(installed)"
    echo "latest:    ${l:-unknown (no network, or $REPO has no releases)}"
    exit 0 ;;
  --version) TAG="${2:?usage: update.sh --version vX.Y.Z}"; ARG="--version $TAG" ;;
  "") ARG="" ;;
  *) echo "usage: update.sh [--version vX.Y.Z | --check]"; exit 2 ;;
esac

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required to update"; exit 1; }
echo "Updating grillscaffold + loop-pilot from $REPO (installed: $(installed))…"
# shellcheck disable=SC2086
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install.sh" | bash -s -- $ARG
