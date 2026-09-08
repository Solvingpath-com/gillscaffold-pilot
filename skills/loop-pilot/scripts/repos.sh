#!/usr/bin/env bash
# loop-pilot repos — the registry behind scan/status/dashboard (~/.loop-pilot/repos.txt).
# Launching a loop registers its repo automatically; removal always requires confirmation.
#
# Usage:
#   repos.sh list                 numbered registry with health of each entry
#   repos.sh add <repo>           register a repo (deduped; auto-called by launch.sh)
#   repos.sh remove <n|path>      remove one entry — asks first (or pass --yes)
#   repos.sh prune                walk dead entries (missing dir / no features) one by one,
#                                 confirm each removal (--yes removes all candidates)
set -uo pipefail

REG_DIR="${LOOP_PILOT_STATE:-$HOME/.loop-pilot}"
REG="$REG_DIR/repos.txt"
mkdir -p "$REG_DIR"; touch "$REG"

CMD="${1:-list}"; shift || true

entries() { grep -v '^\s*#' "$REG" | grep -v '^\s*$' || true; }

health() {  # $1 = repo path → one-line health summary
  local r="$1"
  [ -d "$r" ] || { echo "MISSING — directory gone"; return; }
  local n run=0 f
  n=$(find "$r" -maxdepth 6 -path '*/docs/features/*/status.md' -not -path '*/node_modules/*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -eq 0 ] && { echo "NO-FEATURES — nothing scaffolded here"; return; }
  while IFS= read -r f; do
    local d; d="$(dirname "$f")"
    [ -f "$d/loop.pid" ] && kill -0 "$(cat "$d/loop.pid" 2>/dev/null)" 2>/dev/null && run=$((run+1))
  done < <(find "$r" -maxdepth 6 -path '*/docs/features/*/status.md' -not -path '*/node_modules/*' 2>/dev/null)
  echo "OK — $n feature(s), $run running"
}

do_list() {
  local i=0 e
  if [ -z "$(entries)" ]; then echo "Registry empty ($REG). Launching a loop registers its repo automatically."; return; fi
  while IFS= read -r e; do
    i=$((i+1))
    printf '%2d. %s\n      %s\n' "$i" "$e" "$(health "$e")"
  done < <(entries)
}

do_add() {
  local r="${1:?usage: repos.sh add <repo>}"
  r="$(cd "$r" 2>/dev/null && pwd)" || { echo "ERROR: not a directory: $1"; exit 1; }
  if entries | grep -Fxq "$r"; then
    echo "already registered: $r"
  else
    echo "$r" >> "$REG"
    echo "registered: $r"
  fi
}

confirm() {  # $1 = prompt; honors --yes via $ASSUME_YES
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  if [ -t 0 ]; then
    read -r -p "$1 [y/N] " a; [ "$a" = "y" ] || [ "$a" = "Y" ]
  else
    echo "  (non-interactive and no --yes: skipping)"; return 1
  fi
}

resolve() {  # index or path → exact registry line
  local q="$1"
  if [[ "$q" =~ ^[0-9]+$ ]]; then
    entries | sed -n "${q}p"
  else
    local abs; abs="$(cd "$q" 2>/dev/null && pwd)" || abs="$q"
    entries | grep -Fx "$abs" || entries | grep -Fx "$q" || true
  fi
}

drop_line() {  # remove exact line from registry (grep exits 1 when nothing remains — that's fine)
  local line="$1" tmp
  tmp="$(mktemp)"
  grep -Fxv "$line" "$REG" > "$tmp" || true
  mv "$tmp" "$REG"
}

do_remove() {
  local target="" a
  for a in "$@"; do [ "$a" = "--yes" ] && ASSUME_YES=1 || target="$a"; done
  [ -n "$target" ] || { echo "usage: repos.sh remove <n|path> [--yes]"; exit 1; }
  local line; line="$(resolve "$target")"
  [ -n "$line" ] || { echo "ERROR: no registry entry matches '$target' — see: repos.sh list"; exit 1; }
  echo "entry:  $line"
  echo "health: $(health "$line")"
  if confirm "Remove this repo from the dashboard/scan registry? (repo itself is untouched)"; then
    drop_line "$line"; echo "removed. Re-add any time: repos.sh add $line"
  else
    echo "kept."
  fi
}

do_prune() {
  local a; for a in "$@"; do [ "$a" = "--yes" ] && ASSUME_YES=1; done
  local e h removed=0 kept=0
  while IFS= read -r e; do
    h="$(health "$e")"
    case "$h" in
      OK*) continue ;;
    esac
    echo "candidate: $e"
    echo "  reason:  $h"
    if confirm "  Remove it?"; then drop_line "$e"; removed=$((removed+1)); echo "  removed."
    else kept=$((kept+1)); echo "  kept."; fi
  done < <(entries)
  echo "prune done — removed $removed, kept $kept, healthy entries untouched."
}

case "$CMD" in
  list)   do_list ;;
  add)    do_add "${1:?usage: repos.sh add <repo>}" ;;
  remove) do_remove "$@" ;;
  prune)  do_prune "$@" ;;
  *) echo "usage: repos.sh list | add <repo> | remove <n|path> [--yes] | prune [--yes]"; exit 1 ;;
esac
