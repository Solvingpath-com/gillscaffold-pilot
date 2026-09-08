#!/usr/bin/env bash
# Copy the canonical runner template into grillscaffold so both skills ship the same bytes.
# The canonical copy is loop-pilot's: loop-pilot owns the runner, grillscaffold emits it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/skills/loop-pilot/references/loop-template.md"
DST="$ROOT/skills/grillscaffold/references/loop-template.md"
[ -f "$SRC" ] || { echo "ERROR: canonical template missing: $SRC"; exit 1; }
if cmp -s "$SRC" "$DST"; then echo "already in sync ($(basename "$DST"))"; exit 0; fi
cp "$SRC" "$DST"
echo "synced → $DST"
