#!/usr/bin/env bash
# grillscaffold + loop-pilot uninstaller.
#
#   ./uninstall.sh [--all|--claude|--codex] [--legacy-codex] [--dry-run] [--purge-state] [--keep-backups]
#
# Removes ONLY directories that are our skills (verified by the `name:` field in SKILL.md).
# Never touches your feature folders, your repos, or anyone else's skills.
set -uo pipefail

WANT_CLAUDE=0; WANT_CODEX=0; LEGACY=0; DRY=0; PURGE=0; KEEP_BACKUPS=0
CLAUDE_DIR="$HOME/.claude/skills"
CODEX_DIR="$HOME/.agents/skills"
LEGACY_CODEX_DIR="$HOME/.codex/skills"
STATE_DIR="${LOOP_PILOT_STATE:-$HOME/.loop-pilot}"
SKILLS="grillscaffold loop-pilot"

while [ $# -gt 0 ]; do
  case "$1" in
    --all) WANT_CLAUDE=1; WANT_CODEX=1 ;;
    --claude) WANT_CLAUDE=1 ;;
    --codex) WANT_CODEX=1 ;;
    --legacy-codex) LEGACY=1 ;;
    --dry-run) DRY=1 ;;
    --purge-state) PURGE=1 ;;
    --keep-backups) KEEP_BACKUPS=1 ;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
  shift
done
[ "$WANT_CLAUDE" = 0 ] && [ "$WANT_CODEX" = 0 ] && [ "$LEGACY" = 0 ] && { WANT_CLAUDE=1; WANT_CODEX=1; }

owns() { [ -f "$1/SKILL.md" ] && grep -qE "^name: *$2 *$" "$1/SKILL.md"; }

remove_from() {  # remove_from <label> <root>
  local label="$1" root="$2" s
  [ -d "$root" ] || { echo "$label — nothing at $root"; return 0; }
  echo "$label — $root"
  for s in $SKILLS; do
    if [ ! -e "$root/$s" ]; then echo "  · $s not installed"; continue; fi
    if ! owns "$root/$s" "$s"; then echo "  ⚠ $root/$s is not our skill — left untouched"; continue; fi
    if [ "$DRY" = 1 ]; then echo "  would remove $root/$s"; else rm -rf "$root/$s" && echo "  ✓ removed $s"; fi
  done
  if [ "$KEEP_BACKUPS" = 0 ] && [ -d "$root/.loop-pilot-backups" ]; then
    if [ "$DRY" = 1 ]; then echo "  would remove $root/.loop-pilot-backups"
    else rm -rf "$root/.loop-pilot-backups" && echo "  ✓ removed installer backups"; fi
  fi
}

[ "$WANT_CLAUDE" = 1 ] && remove_from "Claude Code" "$CLAUDE_DIR"
[ "$WANT_CODEX" = 1 ] && remove_from "Codex" "$CODEX_DIR"
[ "$LEGACY" = 1 ] && remove_from "Codex (legacy path)" "$LEGACY_CODEX_DIR"

if [ "$PURGE" = 1 ]; then
  if [ -d "$STATE_DIR" ]; then
    if [ "$DRY" = 1 ]; then echo "would remove $STATE_DIR (repo registry, pause file, notify config)"
    else rm -rf "$STATE_DIR" && echo "✓ removed $STATE_DIR"; fi
  fi
else
  [ -d "$STATE_DIR" ] && echo "kept $STATE_DIR (repo registry / notify config) — remove it with --purge-state"
fi

echo
echo "Your feature folders (docs/features/*) were not touched. Their loop.sh files are"
echo "self-contained and keep working without the skills installed."
[ "$DRY" = 1 ] && echo "(dry run — nothing was removed)"
